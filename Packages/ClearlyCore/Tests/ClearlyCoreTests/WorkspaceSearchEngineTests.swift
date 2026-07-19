import Foundation
import Testing
@testable import ClearlyCore

struct WorkspaceSearchEngineTests {
    @Test func testSearchMatchesTitleAndContent() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file1 = root.appendingPathComponent("ProjectIdeas.md")
        let file2 = root.appendingPathComponent("MeetingNotes.markdown")
        let subfolder = root.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let file3 = subfolder.appendingPathComponent("Todo.md")

        try write("Here is an idea for Antigravity app search.", to: file1)
        try write("Discussed release dates and patch details.", to: file2)
        try write("Shopping list:\n1. Coffee\n2. Antigravity documentation", to: file3)

        let tree = WorkspaceTreeNode.buildTree(at: root)

        // 1. Search for title match
        let titleResults = await WorkspaceSearchEngine.search(query: "ProjectIdeas", in: tree, rootURL: root)
        #expect(titleResults.count >= 1)
        #expect(titleResults.contains(where: { $0.title == "ProjectIdeas" && $0.matchKind == .title }))

        // 2. Search for content match "Antigravity"
        let contentResults = await WorkspaceSearchEngine.search(query: "Antigravity", in: tree, rootURL: root)
        #expect(contentResults.count == 2) // file1 (line 1), file3 (line 3)
        let file3ContentMatch = contentResults.first(where: {
            $0.relativePath == "Docs/Todo.md"
        })
        #expect(file3ContentMatch != nil)
        if case .content(let line, let snippet) = file3ContentMatch?.matchKind {
            #expect(line == 3)
            #expect(snippet.contains("Antigravity"))
        } else {
            Issue.record("Expected content match on line 3")
        }
    }

    @Test func testSearchScopeFiltering() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file1 = root.appendingPathComponent("Notes.md")
        try write("Meeting notes about project roadmap.", to: file1)

        let tree = WorkspaceTreeNode.buildTree(at: root)

        // Title scope searching "Notes" -> should match title
        let titleOnly = await WorkspaceSearchEngine.search(query: "Notes", scope: .title, in: tree, rootURL: root)
        #expect(titleOnly.allSatisfy { $0.matchKind == .title })

        // Content scope searching "Notes" -> should match content on line 1
        let contentOnly = await WorkspaceSearchEngine.search(query: "Notes", scope: .content, in: tree, rootURL: root)
        #expect(contentOnly.allSatisfy { if case .content = $0.matchKind { return true } else { return false } })

        // All scope -> matches both title and content
        let allScope = await WorkspaceSearchEngine.search(query: "Notes", scope: .all, in: tree, rootURL: root)
        #expect(allScope.count == 2)
    }

    @Test func testEmptyQueryReturnsEmpty() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("Hello world", to: root.appendingPathComponent("test.md"))
        let tree = WorkspaceTreeNode.buildTree(at: root)

        let results = await WorkspaceSearchEngine.search(query: "   ", in: tree, rootURL: root)
        #expect(results.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
