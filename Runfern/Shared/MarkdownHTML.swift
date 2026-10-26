import Foundation

/// Converts the Markdown of extension READMEs into simple HTML for display. Covers what READMEs
/// typically use: headings, paragraphs, lists, quotes, code, tables, links, and images. Embedded
/// HTML is passed through, as Markdown allows.
nonisolated enum MarkdownHTML {
    static func document(_ markdown: String, baseURL: URL?) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(baseURL.map { "<base href=\"\($0.deletingLastPathComponent().absoluteString)\">" } ?? "")
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; margin: 20px; line-height: 1.5; word-wrap: break-word; }
        img { max-width: 100%; height: auto; }
        pre { background: rgba(127,127,127,.12); padding: 12px; border-radius: 10px; overflow-x: auto; }
        code { font-family: ui-monospace, monospace; font-size: .92em; }
        :not(pre) > code { background: rgba(127,127,127,.12); padding: 1px 5px; border-radius: 5px; }
        blockquote { margin: 0; padding-left: 14px; border-left: 3px solid rgba(127,127,127,.4); color: gray; }
        table { border-collapse: collapse; } td, th { border: 1px solid rgba(127,127,127,.3); padding: 4px 8px; }
        h1, h2 { border-bottom: 1px solid rgba(127,127,127,.25); padding-bottom: 4px; }
        a { color: -apple-system-blue; }
        </style></head><body>\(html(markdown))</body></html>
        """
    }

    static func html(_ markdown: String) -> String {
        var output: [String] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var codeBlock: [String]?
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { output.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph = []
        }
        func flushList() {
            if let current = list {
                let tag = current.ordered ? "ol" : "ul"
                output.append("<\(tag)>" + current.items.map { "<li>\(inline($0))</li>" }.joined() + "</\(tag)>")
            }
            list = nil
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            let rows = table.filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
            output.append("<table>" + rows.enumerated().map { index, cells in
                let tag = index == 0 ? "th" : "td"
                return "<tr>" + cells.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
            }.joined() + "</table>")
            table = []
        }
        func flushAll() { flushParagraph(); flushList(); flushTable() }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if codeBlock != nil {
                if line.hasPrefix("```") {
                    output.append("<pre><code>\(escape(codeBlock!.joined(separator: "\n")))</code></pre>")
                    codeBlock = nil
                } else {
                    codeBlock!.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") { flushAll(); codeBlock = []; continue }
            if line.isEmpty { flushAll(); continue }
            if line.hasPrefix("|") { flushParagraph(); flushList(); table.append(cells(of: line)); continue }
            flushTable()
            if let level = headingLevel(line) {
                flushAll()
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                output.append("<h\(level)>\(inline(text))</h\(level)>")
            } else if line == "---" || line == "***" || line == "___" {
                flushAll()
                output.append("<hr>")
            } else if line.hasPrefix(">") {
                flushAll()
                output.append("<blockquote>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else if let item = listItem(line) {
                flushParagraph()
                if list == nil || list?.ordered != item.ordered { flushList(); list = (item.ordered, []) }
                list?.items.append(item.text)
            } else if line.hasPrefix("<") {
                // Embedded HTML block, for example centered badges.
                flushAll()
                output.append(rawLine)
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        if let codeBlock { output.append("<pre><code>\(escape(codeBlock.joined(separator: "\n")))</code></pre>") }
        flushAll()
        return output.joined(separator: "\n")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (false, String(line.dropFirst(2)))
        }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return (true, String(line[line.index(dot, offsetBy: 2)...]))
        }
        return nil
    }

    private static func cells(of line: String) -> [String] {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Inline code, images, links, bold, and italics.
    private static func inline(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        // Code spans first, so their content is not formatted.
        while let start = rest.firstIndex(of: "`") {
            result += formatted(String(rest[..<start]))
            let afterStart = rest.index(after: start)
            guard let end = rest[afterStart...].firstIndex(of: "`") else {
                rest = rest[start...]
                break
            }
            result += "<code>\(escape(String(rest[afterStart..<end])))</code>"
            rest = rest[rest.index(after: end)...]
        }
        return result + formatted(String(rest))
    }

    private static func formatted(_ text: String) -> String {
        var html = text
        html = html.replacing(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/) { "<img alt=\"\($0.1)\" src=\"\($0.2)\">" }
        html = html.replacing(/\[([^\]]+)\]\(([^)\s]+)[^)]*\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        html = html.replacing(/\*\*([^*]+)\*\*/) { "<strong>\($0.1)</strong>" }
        html = html.replacing(/(^|[\s(])\*([^*\s][^*]*)\*(?![\w*])/) { "\($0.1)<em>\($0.2)</em>" }
        return html
    }
}
