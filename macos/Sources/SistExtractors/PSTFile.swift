import Foundation
import SistCore

/// An Outlook data file ([MS-PST]): .pst, and .ost in the same format. Read on demand through a
/// file handle, as these files reach tens of gigabytes.
///
/// Three layers: the node database (NDB: two B-trees, one locating blocks by id, one listing
/// nodes, each node a data block or tree of blocks plus a tree of subnodes), the lists, tables
/// and properties layer (LTP: a heap inside a node's data, B-trees inside the heap, property
/// contexts on top) and the messaging layer (folders and messages are nodes holding property
/// contexts; attachments are subnodes of their message). Both the ANSI (Outlook 97-2002) and
/// Unicode formats are read, with either encryption; the 4K-page format of newer .ost files is not.
final class PSTFile {
    struct Node {
        let nid: UInt32
        let data: UInt64
        let sub: UInt64
        let parent: UInt32
    }

    struct Subnode {
        let data: UInt64
        let sub: UInt64
    }

    /// A message of the file, under the name it is indexed as
    struct Message {
        let name: String
        let summary: MessageSummary
    }

    static let rootFolder: UInt32 = 0x122
    static let messageStore: UInt32 = 0x21
    static let typeFolder: UInt32 = 0x02
    static let typeMessage: UInt32 = 0x04
    static let typeAttachment: UInt32 = 0x05

    private let source: ByteSource
    let unicode: Bool
    let encryption: UInt8
    private let nbtRoot: UInt64
    private let bbtRoot: UInt64
    private var pages: [UInt64: [UInt8]] = [:]

    private var idSize: Int { unicode ? 8 : 4 }

    init(_ input: ExtractionInput) throws {
        source = try ByteSource(input)
        let header = try source.read(at: 0, count: 564)
        guard header.count >= 512, header[0..<4].elementsEqual("!BDN".utf8) else {
            throw ExtractionError.invalidFormat("not an Outlook data file")
        }
        let version = Bytes.u16(header, 10)
        switch version {
        case 14, 15:
            unicode = false
            nbtRoot = UInt64(Bytes.u32(header, 188))
            bbtRoot = UInt64(Bytes.u32(header, 196))
            encryption = header[461]
        case 23..<36:
            unicode = true
            nbtRoot = Bytes.u64(header, 224)
            bbtRoot = Bytes.u64(header, 240)
            encryption = header[513]
        default:
            throw ExtractionError.invalidFormat("unsupported data file version \(version)")
        }
        guard encryption <= 2 else {
            throw ExtractionError.invalidFormat("unknown encryption \(encryption)")
        }
    }

    // MARK: Node database

    private func id(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        unicode ? Bytes.u64(bytes, offset) : UInt64(Bytes.u32(bytes, offset))
    }

    /// A B-tree page: its entries, entry size and level
    private func page(at ib: UInt64, type: UInt8) throws -> (bytes: [UInt8], count: Int, entrySize: Int, level: Int) {
        let bytes: [UInt8]
        if let cached = pages[ib] {
            bytes = cached
        } else {
            bytes = try source.read(at: ib, count: 512)
            if pages.count > 4096 {
                pages.removeAll()
            }
            pages[ib] = bytes
        }
        let (meta, trailer) = unicode ? (488, 496) : (496, 500)
        guard bytes.count == 512, bytes[trailer] == type else {
            throw ExtractionError.invalidFormat("bad B-tree page at \(ib)")
        }
        let count = Int(bytes[meta])
        let entrySize = Int(bytes[meta + 2])
        guard entrySize > 0, count * entrySize <= meta else {
            throw ExtractionError.invalidFormat("bad B-tree page at \(ib)")
        }
        return (bytes, count, entrySize, Int(bytes[meta + 3]))
    }

    /// Where a block is and how long, from the block B-tree
    private func blockLocation(_ bid: UInt64) throws -> (ib: UInt64, size: Int)? {
        // The lowest bit of a block id is reserved
        let wanted = bid & ~1
        var ib = bbtRoot
        for _ in 0..<16 {
            let page = try self.page(at: ib, type: 0x80)
            if page.level == 0 {
                for entry in 0..<page.count {
                    let offset = entry * page.entrySize
                    if id(page.bytes, offset) & ~1 == wanted {
                        return (id(page.bytes, offset + idSize), Int(Bytes.u16(page.bytes, offset + 2 * idSize)))
                    }
                }
                return nil
            }
            // The last child whose first key is not above the id
            var next: UInt64?
            for entry in 0..<page.count {
                let offset = entry * page.entrySize
                guard id(page.bytes, offset) & ~1 <= wanted else { break }
                next = id(page.bytes, offset + 2 * idSize)
            }
            guard let next else { return nil }
            ib = next
        }
        return nil
    }

    /// Every node of the node B-tree
    func nodes() throws -> [Node] {
        var nodes: [Node] = []
        var pending: [(ib: UInt64, depth: Int)] = [(nbtRoot, 0)]
        var visited = Set<UInt64>()
        while let (ib, depth) = pending.popLast() {
            guard depth < 16, visited.insert(ib).inserted else { continue }
            let page = try self.page(at: ib, type: 0x81)
            for entry in 0..<page.count {
                let offset = entry * page.entrySize
                if page.level == 0 {
                    nodes.append(Node(nid: UInt32(truncatingIfNeeded: id(page.bytes, offset)),
                                      data: id(page.bytes, offset + idSize), sub: id(page.bytes, offset + 2 * idSize),
                                      parent: Bytes.u32(page.bytes, offset + 3 * idSize)))
                } else {
                    pending.append((id(page.bytes, offset + 2 * idSize), depth + 1))
                }
            }
        }
        return nodes
    }

    /// A block's bytes, decrypted. Internal blocks (data and subnode trees) are never encrypted.
    private func block(_ bid: UInt64) throws -> [UInt8] {
        guard let location = try blockLocation(bid) else {
            throw ExtractionError.invalidFormat("missing block \(bid)")
        }
        var data = try source.read(at: location.ib, count: location.size)
        guard data.count == location.size else {
            throw ExtractionError.invalidFormat("truncated block \(bid)")
        }
        if bid & 2 == 0 {
            PSTCipher.decrypt(&data, method: encryption, key: UInt32(truncatingIfNeeded: bid))
        }
        return data
    }

    /// A node's data: one block, or the blocks an XBLOCK (or XXBLOCK) lists, in order
    func data(_ bid: UInt64, depth: Int = 0) throws -> [[UInt8]] {
        guard bid != 0 else { return [] }
        let block = try self.block(bid)
        guard bid & 2 != 0 else { return [block] }
        guard block.count >= 8, block[0] == 0x01, depth < 3 else {
            throw ExtractionError.invalidFormat("bad data tree block \(bid)")
        }
        var blocks: [[UInt8]] = []
        for entry in 0..<Int(Bytes.u16(block, 2)) {
            let child = id(block, 8 + entry * idSize)
            blocks += block[1] == 1 ? [try self.block(child)] : try data(child, depth: depth + 1)
        }
        return blocks
    }

    /// The subnodes listed by an SLBLOCK, or by the SLBLOCKs an SIBLOCK lists
    func subnodes(_ bid: UInt64, depth: Int = 0) throws -> [UInt32: Subnode] {
        guard bid != 0 else { return [:] }
        let block = try self.block(bid)
        guard block.count >= 4, block[0] == 0x02, depth < 4 else {
            throw ExtractionError.invalidFormat("bad subnode block \(bid)")
        }
        var subnodes: [UInt32: Subnode] = [:]
        let start = unicode ? 8 : 4
        let leaf = block[1] == 0
        let entrySize = (leaf ? 3 : 2) * idSize
        for entry in 0..<Int(Bytes.u16(block, 2)) {
            let offset = start + entry * entrySize
            guard offset + entrySize <= block.count else { break }
            if leaf {
                subnodes[UInt32(truncatingIfNeeded: id(block, offset))] =
                    Subnode(data: id(block, offset + idSize), sub: id(block, offset + 2 * idSize))
            } else {
                subnodes.merge(try self.subnodes(id(block, offset + idSize), depth: depth + 1)) { first, _ in first }
            }
        }
        return subnodes
    }

    // MARK: Lists, tables and properties

    /// The properties of a node or subnode whose data is a property context
    func properties(data: UInt64, subnodes: [UInt32: Subnode]) throws -> MAPIProperties {
        let heap = try PSTHeap(blocks: self.data(data))
        guard heap.clientSignature == 0xBC else {
            throw ExtractionError.invalidFormat("not a property context")
        }
        var properties = MAPIProperties()
        for (key, value) in heap.records(header: heap.userRoot) where key.count >= 2 && value.count >= 6 {
            let type = Bytes.u16(value, 0)
            let cell = Bytes.u32(value, 2)
            let bytes: [UInt8]
            switch type {
            case MAPI.int16, MAPI.int32, MAPI.boolean, 0x0004, 0x000A:
                // Values of up to 4 bytes are stored in place
                bytes = Array(value[2..<6])
            default:
                bytes = try resolve(cell, heap: heap, subnodes: subnodes)
            }
            properties.values[Bytes.u16(key, 0)] = (type, bytes)
        }
        if let codepage = properties.int32(MAPI.internetCodepage) ?? properties.int32(MAPI.messageCodepage) {
            properties.codepage = Int(codepage)
        }
        return properties
    }

    /// A value in the heap (a HID), or in a subnode when it is too large for one (a NID)
    private func resolve(_ hnid: UInt32, heap: PSTHeap, subnodes: [UInt32: Subnode]) throws -> [UInt8] {
        guard hnid != 0 else { return [] }
        if hnid & 0x1F == 0 {
            return heap.allocation(hnid) ?? []
        }
        guard let subnode = subnodes[hnid] else { return [] }
        return Array(try data(subnode.data).joined())
    }

    // MARK: Messaging

    var storeName: String? {
        guard let store = try? nodes().first(where: { $0.nid == Self.messageStore }),
              let properties = try? properties(data: store.data, subnodes: subnodes(store.sub)) else { return nil }
        return properties.string(MAPI.displayName)
    }

    func message(data: UInt64, sub: UInt64, depth: Int = 0) throws -> MessageSummary {
        let subnodes = try self.subnodes(sub)
        var summary = try properties(data: data, subnodes: subnodes).messageSummary()
        guard depth < MailBody.maxDepth else { return summary }
        let attachments = subnodes.keys.filter { $0 & 0x1F == Self.typeAttachment }.sorted()
        for (number, nid) in attachments.enumerated() {
            guard let node = subnodes[nid] else { continue }
            let own = try self.subnodes(node.sub)
            let attachment = try properties(data: node.data, subnodes: own)
            let name = attachment.attachmentName(number: number + 1)
            if attachment.int32(MAPI.attachMethod) == MAPI.attachEmbeddedMessage,
               let object = attachment.binary(MAPI.attachData), object.count >= 4,
               let embedded = own[Bytes.u32(object, 0)] {
                let message = try self.message(data: embedded.data, sub: embedded.sub, depth: depth + 1)
                summary.attachments.append((name + ".eml", message.rfc822()))
            } else {
                summary.attachments.append((name, attachment.binary(MAPI.attachData) ?? []))
            }
        }
        return summary
    }

    /// Calls `body` with each message, in folder order, named `folder/subfolder/00001 subject.eml`.
    /// With `wanted`, only the message of that name is read.
    func forEachMessage(named wanted: String? = nil, _ body: (Message) throws -> Void) throws {
        let nodes = try self.nodes()
        var folders: [UInt32: (name: String, parent: UInt32)] = [:]
        for node in nodes where node.nid & 0x1F == Self.typeFolder {
            let name = (try? properties(data: node.data, subnodes: [:]).string(MAPI.displayName)) ?? ""
            folders[node.nid] = (name, node.parent)
        }
        // The top of the folders the user sees is left out of the names, like the root
        let subtree = folders.first { $0.value.parent == Self.rootFolder && $0.key != Self.rootFolder }?.key

        func path(of folder: UInt32) -> String {
            var parts: [String] = []
            var current = folder
            while current != Self.rootFolder, current != subtree, let entry = folders[current], parts.count < 64 {
                parts.insert(MailExtractor.fileName(entry.name, fallback: "folder"), at: 0)
                current = entry.parent
            }
            return parts.map { $0 + "/" }.joined()
        }

        let messages = Dictionary(grouping: nodes.filter { $0.nid & 0x1F == Self.typeMessage }, by: \.parent)
        for folder in messages.keys.sorted() {
            let prefix = path(of: folder)
            if let wanted, !wanted.hasPrefix(prefix) {
                continue
            }
            for (index, node) in messages[folder, default: []].sorted(by: { $0.nid < $1.nid }).enumerated() {
                let number = String(format: "%05d ", index + 1)
                if let wanted, !wanted.dropFirst(prefix.count).hasPrefix(number) {
                    continue
                }
                // A message that cannot be read keeps its number, so that the others keep theirs
                let summary = (try? message(data: node.data, sub: node.sub)) ?? MessageSummary()
                let name = prefix + number + MailExtractor.fileName(summary.subject ?? "", fallback: "message") + ".eml"
                if let wanted, name != wanted {
                    continue
                }
                try body(Message(name: name, summary: summary))
            }
        }
    }
}

/// A heap-on-node: allocations addressed by HID (block index, allocation index) in a node's data.
struct PSTHeap {
    let blocks: [[UInt8]]

    init(blocks: [[UInt8]]) throws {
        guard let first = blocks.first, first.count >= 12, first[2] == 0xEC else {
            throw ExtractionError.invalidFormat("not a heap-on-node")
        }
        self.blocks = blocks
    }

    var clientSignature: UInt8 { blocks[0][3] }
    var userRoot: UInt32 { Bytes.u32(blocks[0], 4) }

    func allocation(_ hid: UInt32) -> [UInt8]? {
        let index = Int((hid >> 5) & 0x7FF)
        let blockIndex = Int(hid >> 16)
        guard hid & 0x1F == 0, index > 0, blockIndex < blocks.count else { return nil }
        let block = blocks[blockIndex]
        // Every block of the heap starts with the offset of its allocation map
        let map = Int(Bytes.u16(block, 0))
        guard map + 4 <= block.count, index <= Int(Bytes.u16(block, map)) else { return nil }
        let start = Int(Bytes.u16(block, map + 4 + (index - 1) * 2))
        let end = Int(Bytes.u16(block, map + 4 + index * 2))
        guard start <= end, end <= block.count else { return nil }
        return Array(block[start..<end])
    }

    /// The records of the B-tree-on-heap whose header is at `header`
    func records(header hid: UInt32) -> [(key: [UInt8], value: [UInt8])] {
        guard let header = allocation(hid), header.count >= 8, header[0] == 0xB5 else { return [] }
        let keySize = Int(header[1])
        let valueSize = Int(header[2])
        guard keySize > 0, valueSize > 0 else { return [] }
        var records: [(key: [UInt8], value: [UInt8])] = []

        func collect(_ hid: UInt32, level: Int, depth: Int) {
            guard hid != 0, depth < 8, let node = allocation(hid) else { return }
            let size = keySize + (level == 0 ? valueSize : 4)
            for offset in stride(from: 0, through: node.count - size, by: size) {
                if level == 0 {
                    records.append((Array(node[offset..<(offset + keySize)]),
                                    Array(node[(offset + keySize)..<(offset + size)])))
                } else {
                    collect(Bytes.u32(node, offset + keySize), level: level - 1, depth: depth + 1)
                }
            }
        }
        collect(Bytes.u32(header, 4), level: Int(header[3]), depth: 0)
        return records
    }
}

/// Reads parts of a file, or of data in memory, at any offset.
final class ByteSource {
    private let handle: FileHandle?
    private let data: Data?

    init(_ input: ExtractionInput) throws {
        switch input {
        case .file(let path):
            guard let handle = FileHandle(forReadingAtPath: path) else { throw ExtractionError.unreadable(path) }
            self.handle = handle
            data = nil
        case .data(let data, _):
            handle = nil
            self.data = data
        }
    }

    deinit {
        try? handle?.close()
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        if let data {
            guard offset < UInt64(data.count) else { return [] }
            let start = data.startIndex + Int(offset)
            return [UInt8](data[start..<min(data.endIndex, start + count)])
        }
        guard let handle else { return [] }
        try handle.seek(toOffset: offset)
        return [UInt8](try handle.read(upToCount: count) ?? Data())
    }
}

/// [MS-PST] 5.1: "compressible" encryption permutes each byte; "high" encryption also mixes in
/// the block id. The tables are those of the specification (and of libpst and libpff).
enum PSTCipher {
    static func decrypt(_ data: inout [UInt8], method: UInt8, key: UInt32) {
        switch method {
        case 1:
            for index in data.indices {
                data[index] = i[Int(data[index])]
            }
        case 2:
            var w = UInt16(truncatingIfNeeded: key ^ (key >> 16))
            for index in data.indices {
                var byte = data[index] &+ UInt8(truncatingIfNeeded: w)
                byte = r[Int(byte)] &+ UInt8(truncatingIfNeeded: w >> 8)
                byte = s[Int(byte)] &- UInt8(truncatingIfNeeded: w >> 8)
                byte = i[Int(byte)] &- UInt8(truncatingIfNeeded: w)
                data[index] = byte
                w &+= 1
            }
        default:
            break
        }
    }

    static let r: [UInt8] = [
        65, 54, 19, 98, 168, 33, 110, 187, 244, 22, 204, 4, 127, 100, 232, 93,
        30, 242, 203, 42, 116, 197, 94, 53, 210, 149, 71, 158, 150, 45, 154, 136,
        76, 125, 132, 63, 219, 172, 49, 182, 72, 95, 246, 196, 216, 57, 139, 231,
        35, 59, 56, 142, 200, 193, 223, 37, 177, 32, 165, 70, 96, 78, 156, 251,
        170, 211, 86, 81, 69, 124, 85, 0, 7, 201, 43, 157, 133, 155, 9, 160,
        143, 173, 179, 15, 99, 171, 137, 75, 215, 167, 21, 90, 113, 102, 66, 191,
        38, 74, 107, 152, 250, 234, 119, 83, 178, 112, 5, 44, 253, 89, 58, 134,
        126, 206, 6, 235, 130, 120, 87, 199, 141, 67, 175, 180, 28, 212, 91, 205,
        226, 233, 39, 79, 195, 8, 114, 128, 207, 176, 239, 245, 40, 109, 190, 48,
        77, 52, 146, 213, 14, 60, 34, 50, 229, 228, 249, 159, 194, 209, 10, 129,
        18, 225, 238, 145, 131, 118, 227, 151, 230, 97, 138, 23, 121, 164, 183, 220,
        144, 122, 92, 140, 2, 166, 202, 105, 222, 80, 26, 17, 147, 185, 82, 135,
        88, 252, 237, 29, 55, 73, 27, 106, 224, 41, 51, 153, 189, 108, 217, 148,
        243, 64, 84, 111, 240, 198, 115, 184, 214, 62, 101, 24, 68, 31, 221, 103,
        16, 241, 12, 25, 236, 174, 3, 161, 20, 123, 169, 11, 255, 248, 163, 192,
        162, 1, 247, 46, 188, 36, 104, 117, 13, 254, 186, 47, 181, 208, 218, 61,
    ]
    static let s: [UInt8] = [
        20, 83, 15, 86, 179, 200, 122, 156, 235, 101, 72, 23, 22, 21, 159, 2,
        204, 84, 124, 131, 0, 13, 12, 11, 162, 98, 168, 118, 219, 217, 237, 199,
        197, 164, 220, 172, 133, 116, 214, 208, 167, 155, 174, 154, 150, 113, 102, 195,
        99, 153, 184, 221, 115, 146, 142, 132, 125, 165, 94, 209, 93, 147, 177, 87,
        81, 80, 128, 137, 82, 148, 79, 78, 10, 107, 188, 141, 127, 110, 71, 70,
        65, 64, 68, 1, 17, 203, 3, 63, 247, 244, 225, 169, 143, 60, 58, 249,
        251, 240, 25, 48, 130, 9, 46, 201, 157, 160, 134, 73, 238, 111, 77, 109,
        196, 45, 129, 52, 37, 135, 27, 136, 170, 252, 6, 161, 18, 56, 253, 76,
        66, 114, 100, 19, 55, 36, 106, 117, 119, 67, 255, 230, 180, 75, 54, 92,
        228, 216, 53, 61, 69, 185, 44, 236, 183, 49, 43, 41, 7, 104, 163, 14,
        105, 123, 24, 158, 33, 57, 190, 40, 26, 91, 120, 245, 35, 202, 42, 176,
        175, 62, 254, 4, 140, 231, 229, 152, 50, 149, 211, 246, 74, 232, 166, 234,
        233, 243, 213, 47, 112, 32, 242, 31, 5, 103, 173, 85, 16, 206, 205, 227,
        39, 59, 218, 186, 215, 194, 38, 212, 145, 29, 210, 28, 34, 51, 248, 250,
        241, 90, 239, 207, 144, 182, 139, 181, 189, 192, 191, 8, 151, 30, 108, 226,
        97, 224, 198, 193, 89, 171, 187, 88, 222, 95, 223, 96, 121, 126, 178, 138,
    ]
    static let i: [UInt8] = [
        71, 241, 180, 230, 11, 106, 114, 72, 133, 78, 158, 235, 226, 248, 148, 83,
        224, 187, 160, 2, 232, 90, 9, 171, 219, 227, 186, 198, 124, 195, 16, 221,
        57, 5, 150, 48, 245, 55, 96, 130, 140, 201, 19, 74, 107, 29, 243, 251,
        143, 38, 151, 202, 145, 23, 1, 196, 50, 45, 110, 49, 149, 255, 217, 35,
        209, 0, 94, 121, 220, 68, 59, 26, 40, 197, 97, 87, 32, 144, 61, 131,
        185, 67, 190, 103, 210, 70, 66, 118, 192, 109, 91, 126, 178, 15, 22, 41,
        60, 169, 3, 84, 13, 218, 93, 223, 246, 183, 199, 98, 205, 141, 6, 211,
        105, 92, 134, 214, 20, 247, 165, 102, 117, 172, 177, 233, 69, 33, 112, 12,
        135, 159, 116, 164, 34, 76, 111, 191, 31, 86, 170, 46, 179, 120, 51, 80,
        176, 163, 146, 188, 207, 25, 28, 167, 99, 203, 30, 77, 62, 75, 27, 155,
        79, 231, 240, 238, 173, 58, 181, 89, 4, 234, 64, 85, 37, 81, 229, 122,
        137, 56, 104, 82, 123, 252, 39, 174, 215, 189, 250, 7, 244, 204, 142, 95,
        239, 53, 156, 132, 43, 21, 213, 119, 52, 73, 182, 18, 10, 127, 113, 136,
        253, 157, 24, 65, 125, 147, 216, 88, 44, 206, 254, 36, 175, 222, 184, 54,
        200, 161, 128, 166, 153, 152, 168, 47, 14, 129, 101, 115, 228, 194, 162, 138,
        212, 225, 17, 208, 8, 139, 42, 242, 237, 154, 100, 63, 193, 108, 249, 236,
    ]
}
