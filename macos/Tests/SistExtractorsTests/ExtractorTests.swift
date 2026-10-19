import Foundation
import Testing
import ZIPFoundation
import SistCore
@testable import SistExtractors

func zip(_ files: [String: String]) throws -> Data {
    let archive = try Archive(accessMode: .create)
    for (path, text) in files.sorted(by: { $0.key < $1.key }) {
        let data = Data(text.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return try #require(archive.data)
}

func parse(_ data: Data, name: String, options: ScanOptions = ScanOptions()) -> [ParsedDocument] {
    var documents: [ParsedDocument] = []
    DocumentParser(options: options).parse(input: .data(data, name: name), path: "/r/" + name, parentPath: nil,
                                           mtime: 0, size: Int64(data.count), depth: 0) {
        documents.append($0.document)
    }
    return documents
}

@Suite struct ContentBufferTests {
    @Test func collapsesWhitespaceAndStopsAtTheLimit() {
        var buffer = ContentBuffer(limit: 12)
        buffer.append("  hello \t\t world  ")
        buffer.appendLine("again and again")
        #expect(buffer.text == "hello world")
        #expect(buffer.isFull)
        buffer.append("ignored")
        #expect(buffer.text == "hello world")

        var exact = ContentBuffer(limit: 5)
        exact.append("ab cd")
        #expect(exact.text == "ab cd")
        #expect(exact.isFull)
    }
}

@Suite struct TextDecodingTests {
    @Test func encodings() {
        #expect(TextDecoding.decode(Data("héllo 中文".utf8)) == "héllo 中文")
        #expect(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data("bom".utf8)) == "bom")
        #expect(TextDecoding.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0x2D, 0x4E])) == "A中")
        // A prefix cut in the middle of a character is still UTF-8
        let cut = Data("中文".utf8).dropLast()
        #expect(TextDecoding.decode(Data(cut)) == "中")
    }
}

@Suite struct MarkupTests {
    @Test func stripsTagsScriptsAndEntities() {
        let (title, text) = MarkupExtractor.strip("""
            <html><head><title>A &amp; B</title><style>p{color:red}</style>
            <script>var hidden = "<p>no</p>";</script></head>
            <body><!-- comment --><p>First&nbsp;para &#x4E2D;&#25991;</p><div>Second</div></body></html>
            """)
        #expect(title == "A & B")
        var buffer = ContentBuffer(limit: 1000)
        buffer.append(text)
        #expect(buffer.text == "First para 中文\nSecond")
    }
}

@Suite struct DocumentParserTests {
    @Test func json() {
        let documents = parse(Data(#"{"b": ["two", 2], "a": {"x": "one"}}"#.utf8), name: "data.json")
        #expect(documents.map(\.content) == ["one two"])
    }

    @Test func docx() throws {
        let data = try zip([
            "word/document.xml": """
                <w:document xmlns:w="w"><w:body><w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>Word</w:t></w:r></w:p>
                <w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body></w:document>
                """,
            "docProps/core.xml": """
                <cp:coreProperties xmlns:cp="cp" xmlns:dc="dc"><dc:title>Quarterly</dc:title>
                <dc:creator>Wei</dc:creator><cp:lastModifiedBy>Li</cp:lastModifiedBy></cp:coreProperties>
                """,
        ])
        let document = try #require(parse(data, name: "a.docx").first)
        #expect(document.mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(document.content == "Hello Word\n第二段")
        #expect(document.title == "Quarterly")
        #expect(document.metadata[MetaKey.author] == .string("Wei"))
        #expect(document.metadata[MetaKey.modifiedBy] == .string("Li"))
    }

    @Test func pptxSlidesInOrder() throws {
        var files: [String: String] = [:]
        for n in [1, 2, 10] {
            files["ppt/slides/slide\(n).xml"] = "<p:sld xmlns:a=\"a\" xmlns:p=\"p\"><a:p><a:t>slide \(n)</a:t></a:p></p:sld>"
        }
        let document = try #require(parse(try zip(files), name: "deck.pptx").first)
        #expect(document.content == "slide 1\nslide 2\nslide 10")
    }

    @Test func epub() throws {
        let data = try zip([
            "META-INF/container.xml": #"<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>"#,
            "OEBPS/book.opf": """
                <package><metadata><dc:title xmlns:dc="dc">书名</dc:title><dc:creator xmlns:dc="dc">作者</dc:creator></metadata>
                <manifest><item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
                <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
                <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
                """,
            "OEBPS/text/ch1.xhtml": "<html><body><p>第一章</p></body></html>",
            "OEBPS/text/ch2.xhtml": "<html><body><p>第二章</p></body></html>",
        ])
        let document = try #require(parse(data, name: "book.epub").first)
        #expect(document.title == "书名")
        #expect(document.metadata[MetaKey.author] == .string("作者"))
        #expect(document.content == "第一章\n第二章")
    }

    @Test func zipMembersFollowTheirArchive() throws {
        let inner = try zip(["deep.txt": "deep content"])
        let outer = try zip(["a.txt": "member text", "dir/b.html": "<p>html member</p>"])
        // Nest a zip inside a zip
        let nested = try Archive(data: outer, accessMode: .update)
        try nested.addEntry(with: "inner.zip", type: .file, uncompressedSize: Int64(inner.count)) { position, size in
            inner.subdata(in: Int(position)..<Int(position) + size)
        }
        let data = try #require(nested.data)

        let documents = parse(data, name: "outer.zip")
        #expect(documents.map(\.path) == [
            "/r/outer.zip",
            "/r/outer.zip#/a.txt",
            "/r/outer.zip#/dir/b.html",
            "/r/outer.zip#/inner.zip",
            "/r/outer.zip#/inner.zip#/deep.txt",
            "/r/outer.zip#/inner.zip",
            "/r/outer.zip",
        ])
        #expect(documents[1].content == "member text")
        #expect(documents[1].parentPath == "/r/outer.zip")
        #expect(documents[4].parentPath == "/r/outer.zip#/inner.zip")
        #expect(documents[4].content == "deep content")
        #expect(documents.last?.metadata[MetaKey.archiveMembers] == .int(3))

        var shallow = ScanOptions()
        shallow.archiveMode = .shallow
        #expect(!parse(data, name: "outer.zip", options: shallow).map(\.path).contains("/r/outer.zip#/inner.zip#/deep.txt"))

        var list = ScanOptions()
        list.archiveMode = .list
        let listed = parse(data, name: "outer.zip", options: list)
        #expect(listed.count == 1)
        #expect(listed[0].content == "a.txt\ndir/b.html\ninner.zip")
    }

    @Test func brokenFilesAreStillIndexed() {
        let documents = parse(Data("not a zip at all".utf8), name: "broken.docx")
        #expect(documents.count == 1)
        #expect(documents[0].error != nil)
        #expect(documents[0].name == "broken.docx")
    }

    @Test func mimeDetection() {
        let parser = DocumentParser(options: ScanOptions())
        #expect(parser.detectMime(.data(Data("%PDF-1.4".utf8), name: "noext"), ext: "", size: 8, isDirectory: false) == "application/pdf")
        #expect(parser.detectMime(.data(Data(), name: "empty"), ext: "", size: 0, isDirectory: false) == "application/x-empty")
        #expect(parser.detectMime(nil, ext: "MD", size: 1, isDirectory: false) == "text/markdown")
    }
}
