import Foundation
import Testing
import SistCore
@testable import SistExtractors

@Suite struct MobiTests {
    /// The Analects as gutenberg.org builds it for Kindle: MOBI 6, and KF8 (AZW3)
    @Test(arguments: ["lunyu.mobi", "lunyu.azw3"])
    func chineseBook(_ name: String) throws {
        let document = try #require(try parseFile(name).first?.document)
        #expect(document.error == nil)
        #expect(document.category == .document)
        #expect(document.title == "論語")
        #expect(document.metadata[MetaKey.author] == .string("Confucius"))
        #expect(document.metadata[MetaKey.language] == .string("zh"))
        let content = try #require(document.content)
        #expect(content.contains("學而時習之，不亦說乎"))
        #expect(!content.contains("<p"))
        #expect(!content.contains("filepos"))
    }

    @Test func contentStopsAtTheLimit() throws {
        let document = try #require(try parseFile("lunyu.mobi", options: Fixture.options(contentLimit: 500)).first?.document)
        #expect(document.content?.count ?? 0 <= 500)
    }

    @Test func recognizedWithoutExtension() throws {
        let data = try Data(contentsOf: Fixture.url("lunyu.mobi"))
        #expect(MimeTypes.sniff(data) == "application/x-mobipocket-ebook")
    }

    @Test func palmDocDecompression() {
        // Literals, a copy of 4 bytes from 5 back, a space + character pair, a run of 2 raw bytes
        let input: [UInt8] = [0x61, 0x62, 0x63, 0x64, 0x65, 0x80, 0x29, 0xE3, 0x02, 0xFF, 0x00]
        var output: [UInt8] = []
        MobiBook.decompressPalmDoc(input[...], into: &output)
        #expect(output == Array("abcdeabcd c".utf8) + [0xFF, 0x00])

        // A copy reaching before the start is skipped rather than crashing
        output = []
        MobiBook.decompressPalmDoc([0x61, 0x80, 0x29][...], into: &output)
        #expect(output == [0x61])
    }

    @Test func trailingEntries() {
        // One entry whose size (3, itself included) is written backwards at the end
        #expect(MobiBook.trailingSize(of: Array("ABC".utf8) + [0x10, 0x20, 0x83], flags: 0b10) == 3)
        // Then the bytes of a character cut by the record boundary, their count in the low bits
        #expect(MobiBook.trailingSize(of: Array("ABC".utf8) + [0xE5, 0x01, 0x5A, 0x82], flags: 0b11) == 4)
        #expect(MobiBook.trailingSize(of: Array("ABC".utf8), flags: 0) == 0)
        // Garbage never claims more than the record
        #expect(MobiBook.trailingSize(of: [0x7F, 0x7F], flags: 0b10) == 2)
    }

    @Test func damagedFilesAreRejected() throws {
        let data = try [UInt8](Data(contentsOf: Fixture.url("lunyu.mobi")))
        #expect(throws: ExtractionError.self) { try MobiBook(bytes: Array(data.prefix(70))) }
        // Records cut off: the book reads what is there
        let cut = try MobiBook(bytes: Array(data.prefix(20_000)))
        #expect(cut.title == "論語")
        _ = try cut.text(limit: 100_000)
    }
}
