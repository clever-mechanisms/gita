import AppKit
import Testing

@testable import GitaUI

/// Review bodies as bots write them: HTML badges, link reference definitions and deployment tables read as GitHub
/// shows them, never as source.
@MainActor
@Suite("Review Markdown")
struct ReviewMarkdownTests {
    private static let cursorFooter = """
        <div><a href="https://cursor.com/agents/bc-7?ref=pr&amp;cta=web"><picture><source \
        media="(prefers-color-scheme: dark)" srcset="https://cursor.com/dark.png"><img alt="Open in Web" width="114" \
        height="28" src="https://cursor.com/light.png"></picture></a>&nbsp;<a href="https://cursor.com/background">\
        <picture><img alt="Open in Cursor" src="https://cursor.com/c.png"></picture></a></div>
        """

    private static let vercel = """
        [vc]: #qOkV9lkUZnTRsA4R=:eyJpc01vbm9yZXBvIjp0cnVlLCJ0eXBlIjoiZ2l0aHViIn0=
        The latest updates on your projects. Learn more about [Vercel for GitHub](https://vercel.link/github).

        | Project | Deployment | Actions | Updated |
        | :--- | :----- | :------ | :------ |
        | <a href="https://vercel.com/p"><sup><img src="https://vercel.com/avatar" width="16" alt="" /></sup></a> \
        [bambu-bar](https://vercel.com/p) | Error [Error](https://vercel.com/e) |  | \
        <relative-time datetime="2026-11-13T00:26:16.499Z">Nov 13, 2026 12:26am UTC</relative-time> |

        <a href="https://vercel.com/vercel-agent/request-review?owner=o&repo=r&pr=3" rel="noreferrer"><picture>\
        <source media="(prefers-color-scheme: dark)" srcset="https://a.vercel.sh/dark.svg"><img \
        src="https://a.vercel.sh/light.svg" alt="Request Review"></picture></a>
        """

    private func links(_ text: NSAttributedString) -> [String: String] {
        var found: [String: String] = [:]
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value else { return }
            let url = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
            if let span = Range(range, in: text.string) { found[String(text.string[span])] = url }
        }
        return found
    }

    @Test func badgesBecomeLinksNamedByTheirImages() {
        let markdown = ReviewHTML.markdown(Self.cursorFooter)
        #expect(!markdown.contains("<img") && !markdown.contains("<picture") && !markdown.contains("&amp;"))
        let text = ReviewMarkdown.attributed(Self.cursorFooter)
        #expect(text.string.trimmingCharacters(in: .whitespacesAndNewlines) == "Open in Web Open in Cursor")
        #expect(links(text)["Open in Web"] == "https://cursor.com/agents/bc-7?ref=pr&cta=web")
        #expect(links(text)["Open in Cursor"] == "https://cursor.com/background")
    }

    @Test func vercelsCommentReadsAsATable() throws {
        let text = ReviewMarkdown.attributed(Self.vercel)
        let lines = text.string.components(separatedBy: "\n")
        #expect(!text.string.contains("[vc]") && !text.string.contains("<") && !text.string.contains("| :--"))
        #expect(lines.first == "The latest updates on your projects. Learn more about Vercel for GitHub.")
        #expect(lines.contains("Project\tDeployment\tActions\tUpdated"))
        #expect(lines.contains("bambu-bar\tError Error\t\tNov 13, 2026 12:26am UTC"))
        #expect(lines.last == "Request Review")
        #expect(links(text)["Request Review"]?.hasPrefix("https://vercel.com/vercel-agent/request-review") == true)
        #expect(links(text)["bambu-bar"] == "https://vercel.com/p")
        var range = NSRange()
        let header = NSRange(try #require(text.string.range(of: "Project")), in: text.string)
        let style = text.attribute(.paragraphStyle, at: header.location, effectiveRange: &range) as? NSParagraphStyle
        #expect(style?.tabStops.count == 3)
    }

    @Test func codeAndLookalikesStayAsWritten() {
        let body = """
            `<b>kept</b>` and Array<Int> &amp; <b>bold</b><br>next
            ```html
            <div>also kept</div>
            ```
            """
        let markdown = ReviewHTML.markdown(body)
        #expect(markdown.hasPrefix("`<b>kept</b>` and Array<Int> & **bold**\nnext"))
        #expect(markdown.contains("<div>also kept</div>"))
        #expect(ReviewHTML.markdown("``a ` <b>`` <i>x</i> `open") == "``a ` <b>`` *x* `open")
    }

    @Test func imagesLinksAndEntitiesAreChecked() {
        #expect(ReviewHTML.markdown(#"<img src="https://x.dev/a.png">"#) == "[Image](<https://x.dev/a.png>)")
        #expect(ReviewHTML.markdown(#"<img alt="Shot" src="javascript:alert(1)">"#) == "Shot")
        #expect(ReviewHTML.markdown(#"<a href="javascript:alert(1)">click</a>"#) == "click")
        #expect(
            ReviewHTML.markdown(#"<a href='https://x.dev'>[x]</a><a href="https://y.dev">"#)
                == #"[\[x\]](<https://x.dev>)"#)
        #expect(ReviewHTML.markdown("<ul><li>one</li><li>two</li></ul>") == "\n- one\n- two\n")
        #expect(ReviewHTML.markdown("<details><summary>More</summary>\n\n\n\nBody</details>") == "\nMore\n\nBody\n")
        #expect(ReviewHTML.markdown("&#8594; &#x41; &unknown; &#0; & alone") == "→ A &unknown; &#0; & alone")
        #expect(ReviewHTML.markdown("<table><tr><td>a</td><td>b</td></tr></table>").contains("a b"))
        #expect(ReviewHTML.markdown("<custom-tag>x</custom-tag> <a") == "<custom-tag>x</custom-tag> <a")
        #expect(ReviewHTML.markdown("<s>old</s> <code>new</code>") == "~~old~~ `new`")
    }

    @Test func definitionsTablesAndRowsAreRecognised() {
        #expect(ReviewMarkdown.blocks("[a]: https://x.dev") == [.hidden])
        #expect(ReviewMarkdown.blocks(#"[a]: https://x.dev "Title""#) == [.hidden])
        #expect(ReviewMarkdown.blocks("[WIP]: fix things") == [.plain("[WIP]: fix things")])
        #expect(ReviewMarkdown.blocks("[^1]: note") == [.plain("[^1]: note")])
        #expect(
            ReviewMarkdown.blocks("a | b\n--|--\n1 | 2\nafter") == [
                .row(["a", "b"], header: true), .hidden, .row(["1", "2"], header: false), .plain("after"),
            ])
        #expect(ReviewTable.cells(#"| `a|b` | c\|d |"#) == ["`a|b`", "c|d"])
        #expect(!ReviewTable.isDelimiter("| a | b |"))
        #expect(!ReviewTable.isDelimiter("|  |"))
        #expect(ReviewTable.isDelimiter(":-:|---:"))
        #expect(ReviewMarkdown.blocks("x | y\nplain") == [.plain("x | y"), .plain("plain")])
    }
}
