import Foundation
import Testing
@testable import ClearlyCore

struct WorkspaceTreeNodeTests {
    @Test func buildsAlphabeticalMarkdownAndImageTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("", to: root.appendingPathComponent("z.md"))
        try write("", to: root.appendingPathComponent("A.markdown"))
        try write("", to: root.appendingPathComponent("diagram.png"))
        try write("", to: root.appendingPathComponent("ignored.swift"))

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("", to: folder.appendingPathComponent("Notes.txt"))

        let tree = WorkspaceTreeNode.buildTree(at: root)

        #expect(tree.map(\.name) == ["A.markdown", "diagram.png", "Folder", "z.md"])
        #expect(tree.first(where: { $0.name == "diagram.png" })?.kind == .image)
        #expect(tree.first(where: { $0.name == "Folder" })?.children?.map(\.name) == ["Notes.txt"])
    }

    @Test func skipsHiddenHeavyAndSymlinkedDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let git = root.appendingPathComponent(".git", isDirectory: true)
        let modules = root.appendingPathComponent("node_modules", isDirectory: true)
        let real = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try write("", to: git.appendingPathComponent("secret.md"))
        try write("", to: modules.appendingPathComponent("package.md"))
        try write("", to: real.appendingPathComponent("visible.md"))
        try write("", to: root.appendingPathComponent(".hidden.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Loop"),
            withDestinationURL: root
        )

        let tree = WorkspaceTreeNode.buildTree(at: root)

        #expect(tree.map(\.name) == ["Real"])
        #expect(WorkspaceTreeNode.firstEditableFile(in: tree)?.lastPathComponent == "visible.md")
    }

    @Test func canIncludeHiddenFilesWithoutIncludingIgnoredDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("", to: root.appendingPathComponent(".notes.md"))
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try write("", to: git.appendingPathComponent("ignored.md"))

        let tree = WorkspaceTreeNode.buildTree(at: root, showHiddenFiles: true)

        #expect(tree.map(\.name) == [".notes.md"])
    }

    @Test func respectsTheGlobalItemLimit() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<10 {
            try write("", to: root.appendingPathComponent("\(index).md"))
        }

        let tree = WorkspaceTreeNode.buildTree(at: root, maximumItemCount: 3)

        #expect(tree.count == 3)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
