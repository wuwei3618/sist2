import Foundation
import Testing
import ZIPFoundation
import SistCore
@testable import SistExtractors

/// Fixtures are made by Fixtures/generate.py
enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
    }

    /// The single file inside one of the zipped fixtures
    static func unzipped(_ name: String) throws -> Data {
        let archive = try Archive(url: url(name + ".zip"), accessMode: .read)
        let entry = try #require(archive[name])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    static func options(contentLimit: Int = 32_768) -> ScanOptions {
        var options = ScanOptions()
        // QuickLook would otherwise be asked for thumbnails on macOS
        options.thumbnailCount = 0
        options.contentSizeLimit = contentLimit
        return options
    }
}

func parseFile(_ name: String, options: ScanOptions = Fixture.options()) throws -> [ParseResult] {
    let path = Fixture.url(name).path
    let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0
    var results: [ParseResult] = []
    DocumentParser(options: options).parse(FileEntry(path: path, mtime: 0, size: size)) { results.append($0) }
    return results
}

func parseBytes(_ data: Data, name: String, options: ScanOptions = Fixture.options()) -> [ParsedDocument] {
    var documents: [ParsedDocument] = []
    DocumentParser(options: options).parse(input: .data(data, name: name), path: "/r/" + name, parentPath: nil,
                                           mtime: 0, size: Int64(data.count), depth: 0) {
        documents.append($0.document)
    }
    return documents
}

@Suite struct ArchiveTests {
    @Test(arguments: ["archive.tar.gz", "archive.7z", "archive.rar"])
    func membersKeepTheirChineseNames(_ name: String) throws {
        let documents = try parseFile(name).map(\.document)
        let archive = Fixture.url(name).path
        let members = Dictionary(documents.filter { $0.parentPath == archive }.map { ($0.path, $0) },
                                 uniquingKeysWith: { first, _ in first })

        let readme = try #require(members[archive + "#/docs/说明.txt"], "\(documents.map(\.path))")
        #expect(readme.content == "压缩包里的中文说明 archive readme")
        #expect(readme.name == "说明.txt")
        #expect(members[archive + "#/docs/notes.md"]?.content == "tar member mentions walrus")

        // The archive comes first so members can reference it, and again once complete
        #expect(documents.first?.path == archive)
        #expect(documents.last?.path == archive)
        #expect(documents.last?.metadata[MetaKey.archiveMembers] != nil)
    }

    @Test func archiveInsideArchive() throws {
        let documents = try parseFile("archive.tar.gz").map(\.document)
        let deep = try #require(documents.first { $0.path.hasSuffix("#/inner.zip#/deep.txt") })
        #expect(deep.content == "nested zip inside tar mentions narwhal")
        #expect(deep.parentPath == Fixture.url("archive.tar.gz").path + "#/inner.zip")
    }

    @Test func compressedFileThatIsNotAnArchive() throws {
        let documents = try parseFile("notes.txt.gz").map(\.document)
        let member = try #require(documents.first { $0.parentPath != nil })
        #expect(member.name == "notes.txt")
        #expect(member.mime == "text/plain")
        #expect(member.content == "single gzip file mentions pelican")
    }

    @Test func zipNamesWithoutTheUTF8Flag() throws {
        let documents = try parseFile("gbk-names.zip").map(\.document)
        let member = try #require(documents.first { $0.parentPath != nil })
        #expect(member.name == "中文名.txt")
        #expect(member.content == "gbk named member mentions albatross")
    }

    @Test func comicBooksGetACoverNotMembers() throws {
        var options = Fixture.options()
        options.thumbnailCount = 1
        let results = try parseFile("comic.cbr", options: options)
        #expect(results.count == 1)
        #expect(results[0].document.metadata[MetaKey.pages] == .int(2))
        #if canImport(ImageIO)
        #expect(results[0].thumbnails.count == 1)
        #endif
    }

    @Test func oversizedMembersAreIndexedByName() throws {
        var options = Fixture.options()
        options.maxArchiveMemberSize = 10
        let members = try parseFile("archive.7z", options: options).map(\.document).filter { $0.parentPath != nil }
        #expect(Set(members.map(\.name)) == ["说明.txt", "notes.md"])
        #expect(members.allSatisfy { $0.content == nil && $0.size > 10 })
    }

    @Test func listMode() throws {
        var options = Fixture.options()
        options.archiveMode = .list
        let documents = try parseFile("archive.rar", options: options).map(\.document)
        #expect(documents.count == 1)
        #expect(documents[0].content == "docs/notes.md\ndocs/说明.txt")
    }

    @Test func membersCanBeReadBackOut() throws {
        let tar = Fixture.url("archive.tar.gz").path
        #expect(String(decoding: try ArchiveMemberReader.data(forPath: tar + "#/docs/说明.txt"), as: UTF8.self)
                == "压缩包里的中文说明 archive readme")
        // Nested, then a member of a plain compressed file, then a legacy-encoded name
        #expect(String(decoding: try ArchiveMemberReader.data(forPath: tar + "#/inner.zip#/deep.txt"), as: UTF8.self)
                == "nested zip inside tar mentions narwhal")
        #expect(String(decoding: try ArchiveMemberReader.data(forPath: Fixture.url("notes.txt.gz").path + "#/notes.txt"),
                       as: UTF8.self) == "single gzip file mentions pelican")
        #expect(String(decoding: try ArchiveMemberReader.data(forPath: Fixture.url("gbk-names.zip").path + "#/中文名.txt"),
                       as: UTF8.self) == "gbk named member mentions albatross")

        // Every member the extractor indexes can be read back by the path it was indexed under
        for name in ["archive.7z", "archive.rar", "archive.tar.gz"] {
            for document in try parseFile(name).map(\.document) where document.parentPath != nil {
                #expect(try ArchiveMemberReader.data(forPath: document.path).count == document.size)
            }
        }

        #expect(throws: ExtractionError.self) {
            _ = try ArchiveMemberReader.data(forPath: tar + "#/missing.txt")
        }
        let url = try ArchiveMemberReader.extractToTemporaryFile(path: tar + "#/docs/notes.md", documentId: 42)
        #expect(url.lastPathComponent == "notes.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "tar member mentions walrus")
    }

    @Test func brokenArchivesAreStillIndexed() {
        let documents = parseBytes(Data("definitely not 7z".utf8), name: "broken.7z")
        #expect(documents.count == 1)
        #expect(documents[0].error != nil)
    }
}

@Suite struct LegacyOfficeTests {
    @Test func excel() throws {
        let document = try #require(try parseFile("sample.xls").first?.document)
        #expect(document.title == "测试工作簿")
        #expect(document.metadata[MetaKey.author] == .string("张三"))
        // Sheet names, then the shared strings
        #expect(document.content == "销售\nSummary\n季度销售报告\n华东地区\nQuarterly revenue grew")
        #expect(document.error == nil)
    }

    @Test func excelStringsSpanningContinueRecords() throws {
        let data = try Fixture.unzipped("many-strings.xls")
        let document = try #require(parseBytes(data, name: "many-strings.xls",
                                                options: Fixture.options(contentLimit: 500_000)).first)
        let expected = ["Sheet"]
            + (1...3000).map { $0 % 2 == 1 ? String(format: "条目%04d 中文内容", $0) : String(format: "entry %04d latin text", $0) }
            + ["最后一个条目 final entry"]
        let lines = try #require(document.content).components(separatedBy: "\n")
        #expect(lines.count == expected.count)
        #expect(lines == expected)
    }

    @Test func powerPoint() throws {
        let document = try #require(parseBytes(try Fixture.unzipped("sample.ppt"), name: "sample.ppt").first)
        #expect(document.title == "测试演示文稿")
        #expect(document.metadata[MetaKey.author] == .string("李四"))
        let lines = try #require(document.content).components(separatedBy: "\n")
        for text in ["年度总结", "Annual review", "第二页", "企鹅数量增长 penguin growth",
                     "文本框内容 textbox words", "演讲者备注 speaker notes"] {
            #expect(lines.contains(text), "\(text) in \(lines)")
        }
        #expect(Set(lines).count == lines.count)
        #expect(!lines.contains("*"))
    }

    @Test func powerPointInsideAZip() throws {
        let documents = try parseFile("sample.ppt.zip").map(\.document)
        let member = try #require(documents.first { $0.name == "sample.ppt" })
        #expect(member.mime == "application/vnd.ms-powerpoint")
        #expect(member.title == "测试演示文稿")
    }

    @Test func compoundFileWithoutExtension() throws {
        let data = try Data(contentsOf: Fixture.url("sample.xls"))
        let document = try #require(parseBytes(data, name: "noextension").first)
        #expect(document.mime == "application/x-ole-storage")
        #expect(document.content?.contains("季度销售报告") == true)
    }

    /// Corrupted files must give an error or partial text, never a crash or a hang
    @Test func corruptedFilesAreSurvived() throws {
        let originals = [("sample.xls", try Data(contentsOf: Fixture.url("sample.xls"))),
                         ("sample.ppt", try Fixture.unzipped("sample.ppt"))]
        var random = SplitMix(seed: 42)
        for (name, original) in originals {
            for _ in 0..<150 {
                var bytes = [UInt8](original)
                for _ in 0..<(1 + Int(random.next() % 40)) {
                    let position = Int(random.next() % UInt64(bytes.count))
                    bytes[position] = UInt8(truncatingIfNeeded: random.next())
                }
                if random.next() % 4 == 0 {
                    bytes = Array(bytes.prefix(Int(random.next() % UInt64(bytes.count))))
                }
                #expect(parseBytes(Data(bytes), name: name).count == 1)
            }
        }
    }
}

struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
