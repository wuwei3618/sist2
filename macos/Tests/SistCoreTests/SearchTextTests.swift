import Testing
@testable import SistCore

@Suite struct SearchTextTests {
    func tokens(_ text: String) -> [String] {
        SearchText.indexable(text).split(separator: " ").map(String.init)
    }

    @Test func cjkRunsBecomeBigramsAndTrailingUnigram() {
        #expect(tokens("文档管理") == ["文档", "档管", "管理", "理"])
        #expect(tokens("文") == ["文"])
    }

    @Test func otherScriptsAreLeftToTheTokenizer() {
        #expect(SearchText.indexable("hello world") == "hello world")
        #expect(tokens("iPhone手机壳") == ["iPhone", "手机", "机壳", "壳"])
        #expect(tokens("한국어 텍스트") == ["한국", "국어", "어", "텍스", "스트", "트"])
    }

    @Test func fullWidthIsFolded() {
        #expect(SearchText.indexable("ＡＢＣ１２３") == "ABC123")
    }

    @Test func queryPhrases() {
        #expect(SearchText.queryPhrase("文档") == ("文档", false))
        #expect(SearchText.queryPhrase("文档管理") == ("文档 档管 管理", false))
        // A single character can only be found as the start of a bigram
        #expect(SearchText.queryPhrase("文") == ("文", true))
        #expect(SearchText.queryPhrase("b文") == ("b 文", true))
        // A run followed by more text must end where the indexed run ends
        #expect(SearchText.queryPhrase("文字b") == ("文字 字 b", false))
        #expect(SearchText.queryPhrase("hello") == ("hello", false))
    }
}

@Suite struct QueryParserTests {
    @Test func termsAreAndedAndQuoted() {
        #expect(QueryParser.parse("foo bar").ftsExpression == "\"foo\" AND \"bar\"")
    }

    @Test func orBindsItsNeighbours() {
        #expect(QueryParser.parse("a b OR c d").ftsExpression == "\"a\" AND (\"b\" OR \"c\") AND \"d\"")
        #expect(QueryParser.parse("a | b").ftsExpression == "(\"a\" OR \"b\")")
    }

    @Test func exclusions() {
        #expect(QueryParser.parse("report -draft").ftsExpression == "(\"report\") NOT (\"draft\")")
        // Nothing to match on: FTS5 cannot express a pure negation
        #expect(QueryParser.parse("-draft").ftsExpression == nil)
    }

    @Test func phrasesPrefixesAndColumns() {
        #expect(QueryParser.parse("\"quick brown\"").ftsExpression == "\"quick brown\"")
        #expect(QueryParser.parse("photo*").ftsExpression == "\"photo\"*")
        #expect(QueryParser.parse("name:report").ftsExpression == "name : \"report\"")
        #expect(QueryParser.parse("unknown:report").ftsExpression == "\"unknown:report\"")
    }

    @Test func cjk() {
        #expect(QueryParser.parse("季度报告").ftsExpression == "\"季度 度报 报告\"")
        #expect(QueryParser.parse("报").ftsExpression == "\"报\"*")
    }

    @Test func hostileInputNeverBreaksTheSyntax() {
        for input in ["\"", "\"unbalanced", "a\"b", "(((", "AND OR NOT", "*", "-", ":", "name:", "' OR 1=1 --"] {
            let parsed = QueryParser.parse(input)
            if let expression = parsed.ftsExpression {
                #expect(expression.filter { $0 == "\"" }.count % 2 == 0, "\(input) -> \(expression)")
            }
        }
        #expect(QueryParser.parse("   ").ftsExpression == nil)
        #expect(QueryParser.parse("!!! ???").ftsExpression == nil)
    }

    @Test func highlightTerms() {
        #expect(QueryParser.parse("foo \"bar baz\" -qux pre*").highlightTerms == ["foo", "bar baz", "pre"])
    }
}

@Suite struct HighlighterTests {
    @Test func marksAllMatchesCaseInsensitively() {
        let snippet = Highlighter.highlight("Report and REPORTS", terms: ["report"])
        #expect(snippet.segments.filter(\.highlighted).map(\.text) == ["Report", "REPORT"])
        #expect(snippet.plainText == "Report and REPORTS")
    }

    @Test func excerptCentersOnTheMatches() throws {
        let text = String(repeating: "lorem ipsum ", count: 100) + "the needle is here" + String(repeating: " dolor", count: 100)
        let excerpt = try #require(Highlighter.excerpt(text, terms: ["needle"], length: 80))
        #expect(excerpt.segments.first?.text == "…")
        #expect(excerpt.segments.last?.text == "…")
        #expect(excerpt.segments.contains { $0.highlighted && $0.text == "needle" })
        #expect(excerpt.plainText.count < 100)
    }

    @Test func excerptPrefersTheWindowWithMoreDistinctTerms() throws {
        let text = "alpha " + String(repeating: "x ", count: 300) + "alpha beta" + String(repeating: " y", count: 300)
        let excerpt = try #require(Highlighter.excerpt(text, terms: ["alpha", "beta"], length: 60))
        #expect(Set(excerpt.segments.filter(\.highlighted).map(\.text)) == ["alpha", "beta"])
    }

    @Test func excerptWithoutMatchesIsTheBeginning() throws {
        let excerpt = try #require(Highlighter.excerpt("  first words of the text", terms: ["absent"], length: 11))
        #expect(excerpt.plainText == "first words")
        #expect(!excerpt.hasHighlights)
    }

    @Test func cjk() {
        let snippet = Highlighter.highlight("这是季度报告的摘要", terms: ["报告"])
        #expect(snippet.segments.map(\.text) == ["这是季度", "报告", "的摘要"])
    }
}
