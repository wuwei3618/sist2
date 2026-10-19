import Foundation
import Testing
@testable import SistCore

func makeTemporaryDirectory() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("sist-test-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

@Suite struct IgnoreListTests {
    let list = IgnoreList(root: "/root", patterns: [
        "# comment", "", "*.log", "!keep.log", "build/", "/top-only.txt", "docs/**/draft*", "[Tt]emp",
    ])

    @Test func unanchoredPatternsMatchAnywhere() {
        #expect(list.isIgnored("/root/a.log", isDirectory: false))
        #expect(list.isIgnored("/root/x/y/b.log", isDirectory: false))
        #expect(!list.isIgnored("/root/x/keep.log", isDirectory: false))
        #expect(list.isIgnored("/root/x/Temp", isDirectory: true))
    }

    @Test func directoryOnlyPatterns() {
        #expect(list.isIgnored("/root/src/build", isDirectory: true))
        #expect(!list.isIgnored("/root/src/build", isDirectory: false))
    }

    @Test func anchoredPatterns() {
        #expect(list.isIgnored("/root/top-only.txt", isDirectory: false))
        #expect(!list.isIgnored("/root/sub/top-only.txt", isDirectory: false))
        #expect(list.isIgnored("/root/docs/draft1.md", isDirectory: false))
        #expect(list.isIgnored("/root/docs/a/b/draft2.md", isDirectory: false))
        #expect(!list.isIgnored("/root/other/draft.md", isDirectory: false))
    }
}

@Suite struct DirectoryWalkerTests {
    @Test func walksRegularFilesWithPruning() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("a", to: root + "/a.txt")
        try write("b", to: root + "/sub/b.txt")
        try write("c", to: root + "/sub/deeper/c.txt")
        try write("h", to: root + "/.hidden/h.txt")
        try write("x", to: root + "/excluded/x.txt")
        try write("i", to: root + "/ignored/i.txt")
        try write("ignored/\n", to: root + "/.sistignore")
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/sub")

        var options = ScanOptions()
        options.excludePattern = "/excluded/"
        let walker = try DirectoryWalker(root: root, options: options)
        let paths = Set(walker.map { $0.path.replacingOccurrences(of: root, with: "") })
        #expect(paths == ["/a.txt", "/sub/b.txt", "/sub/deeper/c.txt"])

        options.maxDepth = 1
        let shallow = try DirectoryWalker(root: root, options: options)
        #expect(Set(shallow.map { $0.path.replacingOccurrences(of: root, with: "") }) == ["/a.txt", "/sub/b.txt"])
    }

    @Test func reportsSizeAndMtime() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("12345", to: root + "/five.txt")
        let entry = try #require(try DirectoryWalker(root: root, options: ScanOptions()).next())
        #expect(entry.size == 5)
        #expect(abs(Double(entry.mtime) - Date().timeIntervalSince1970) < 60)
    }

    @Test func missingRootThrows() {
        #expect(throws: WalkError.self) {
            _ = try DirectoryWalker(root: "/nonexistent-\(UUID().uuidString)", options: ScanOptions())
        }
    }
}

@Suite struct MimeTypesTests {
    @Test func sniffing() {
        #expect(MimeTypes.sniff(Data("%PDF-1.7".utf8)) == "application/pdf")
        #expect(MimeTypes.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])) == "image/png")
        #expect(MimeTypes.sniff(Data("PK\u{03}\u{04}rest".utf8)) == "application/zip")
        #expect(MimeTypes.sniff(Data("<!DOCTYPE html><html>".utf8)) == "text/html")
        #expect(MimeTypes.sniff(Data("plain words\nmore".utf8)) == "text/plain")
        #expect(MimeTypes.sniff(Data("中文文本".utf8)) == "text/plain")
        #expect(MimeTypes.sniff(Data([0x00, 0x13, 0x88, 0x00, 0x01, 0x02])) == nil)
    }

    @Test func categories() {
        #expect(MimeCategory(mime: "application/pdf") == .document)
        #expect(MimeCategory(mime: "image/heic") == .image)
        #expect(MimeCategory(mime: "application/zip") == .archive)
        #expect(MimeCategory(mime: "application/json") == .text)
        #expect(MimeCategory(mime: "application/x-unknown") == .other)
        #expect(MimeCategory(mime: nil) == .other)
    }
}

@Suite struct FrameChannelTests {
    @Test func roundTripsThroughAPipe() throws {
        let pipe = Pipe()
        let channel = FrameChannel(readFD: pipe.fileHandleForReading.fileDescriptor,
                                   writeFD: pipe.fileHandleForWriting.fileDescriptor)
        let entry = FileEntry(path: "/a/文件.txt", mtime: 42, size: 7)
        try channel.write(.job, json: entry)
        try channel.write(Frame(type: .thumbnail, payload: Data([1, 2, 3])))
        try channel.write(Frame(type: .bye))
        try pipe.fileHandleForWriting.close()

        let job = try #require(try channel.read())
        #expect(job.type == .job)
        #expect(try JSONDecoder().decode(FileEntry.self, from: job.payload) == entry)
        #expect(try channel.read()?.payload == Data([1, 2, 3]))
        #expect(try channel.read()?.type == .bye)
        #expect(try channel.read() == nil)
    }

    @Test func rejectsGarbage() {
        #expect(throws: FrameError.self) {
            _ = try FrameCodec.decodeHeader(Data([99, 0, 0, 0, 0, 0, 0, 0]))
        }
    }
}
