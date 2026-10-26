import Testing
@testable import Runfern

/// Verifies the README rendering of extensions.
@Suite struct MarkdownHTMLTests {
    @Test func rendersCommonBlocks() {
        let html = MarkdownHTML.html("""
        # Python
        Supports **IntelliSense** and *linting*. See [docs](https://example.com).

        - one
        - two

        ```
        print("<hi>")
        ```
        """)
        #expect(html.contains("<h1>Python</h1>"))
        #expect(html.contains("<strong>IntelliSense</strong>"))
        #expect(html.contains("<em>linting</em>"))
        #expect(html.contains("<a href=\"https://example.com\">docs</a>"))
        #expect(html.contains("<ul><li>one</li><li>two</li></ul>"))
        #expect(html.contains("print(\"&lt;hi&gt;\")"))
    }

    @Test func inlineCodeIsNotFormatted() {
        #expect(MarkdownHTML.html("Use `**raw**` here").contains("<code>**raw**</code>"))
    }
}
