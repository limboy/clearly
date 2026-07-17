import Testing
@testable import ClearlyCore

@Suite(.serialized)
struct MarkdownCalloutTests {
    @Test func nestedBlockquoteKeepsFollowingParagraphInsideCallout() throws {
        let markdown = """
        > [!info] Question
        > > 当外界环境中出现重要、威胁或高度奖赏的刺激时，脑岛首先产生生理唤起信号并提取其主观感受（“有重要的事情正在发生”）
        >
        > 脑岛不是主要负责内感受的吗？为什么环境中出现的刺激也是它先唤醒？
        """

        let html = MarkdownRenderer.renderHTML(markdown)
        let contentStart = try #require(html.range(of: "<div class=\"callout-content\">"))
        let contentEnd = try #require(
            html.range(of: "</div></div>", range: contentStart.upperBound..<html.endIndex)
        )
        let nestedQuoteEnd = try #require(
            html.range(of: "</blockquote>", range: contentStart.upperBound..<contentEnd.lowerBound)
        )
        let followingParagraph = try #require(html.range(of: "脑岛不是主要负责内感受的吗？"))

        #expect(nestedQuoteEnd.upperBound < followingParagraph.lowerBound)
        #expect(followingParagraph.upperBound < contentEnd.lowerBound)
        #expect(html.components(separatedBy: "<blockquote").count - 1 == 1)
        #expect(html.components(separatedBy: "</blockquote>").count - 1 == 1)
    }

    @Test func simpleAndFoldableCalloutsStillRender() {
        let markdown = """
        > [!NOTE] Title
        > Body

        > [!TIP]- More
        > Hidden body
        """

        let html = MarkdownRenderer.renderHTML(markdown)

        #expect(html.contains("<div class=\"callout callout-note\""))
        #expect(html.contains("<span class=\"callout-title-text\">Title</span>"))
        #expect(html.contains("<p>Body</p>"))
        #expect(html.contains("<details class=\"callout callout-tip\""))
        #expect(html.contains("<span class=\"callout-title-text\">More</span>"))
        #expect(html.contains("<p>Hidden body</p>"))
    }
}
