import Foundation

public enum WorkspaceTreeNodeKind: Hashable, Sendable {
    case folder
    case markdown
    case image
}

/// A lightweight folder tree for the macOS workspace sidebar.
///
/// Clearly only exposes Markdown/text documents and their common image assets.
/// Heavy dependency, build, cache, and version-control directories are skipped
/// so opening a broad project folder cannot accidentally walk millions of files.
public struct WorkspaceTreeNode: Identifiable, Hashable, Sendable {
    public let name: String
    public let url: URL
    public let kind: WorkspaceTreeNodeKind
    public let children: [WorkspaceTreeNode]?

    public var id: URL { url }
    public var isDirectory: Bool { kind == .folder }
    public var isEditable: Bool { kind == .markdown }

    /// Hierarchical views use `nil` for empty folders so they do not show a
    /// disclosure chevron with nothing underneath it.
    public var displayChildren: [WorkspaceTreeNode]? {
        guard let children, !children.isEmpty else { return nil }
        return children
    }

    public var displayName: String {
        isDirectory ? name : url.deletingPathExtension().lastPathComponent
    }

    public static let editableExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx", "txt",
    ]

    public static let imageExtensions: Set<String> = [
        "avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tiff", "webp",
    ]

    public static let ignoredDirectories: Set<String> = [
        ".build", ".bundle", ".cache", ".docker", ".git", ".gradle", ".hg",
        ".idea", ".next", ".nuxt", ".nyc_output", ".output", ".parcel-cache",
        ".pub-cache", ".sass-cache", ".svn", ".terraform", ".tox", ".vagrant",
        ".venv", ".vs", ".vscode", "__pycache__", "_site", "bower_components",
        "build", "coverage", "DerivedData", "dist", "node_modules", "out", "Pods",
        "target", "vendor", "venv", "xcuserdata",
    ]

    /// Recursively builds a bounded workspace tree.
    ///
    /// Symbolic links are skipped to avoid cycles. `maximumItemCount` is shared
    /// across the entire walk and protects the UI from unexpectedly broad roots.
    public static func buildTree(
        at rootURL: URL,
        showHiddenFiles: Bool = false,
        maximumItemCount: Int = 20_000,
        isCancelled: () -> Bool = { false }
    ) -> [WorkspaceTreeNode] {
        var remaining = max(0, maximumItemCount)
        return buildTree(
            at: rootURL.standardizedFileURL,
            showHiddenFiles: showHiddenFiles,
            remaining: &remaining,
            depth: 0,
            isCancelled: isCancelled
        )
    }

    public static func firstEditableFile(in nodes: [WorkspaceTreeNode]) -> URL? {
        for node in nodes {
            if node.isEditable {
                return node.url
            }
            if let children = node.children,
               let match = firstEditableFile(in: children) {
                return match
            }
        }
        return nil
    }

    public static func contains(_ targetURL: URL, in nodes: [WorkspaceTreeNode]) -> Bool {
        let target = targetURL.standardizedFileURL
        for node in nodes {
            if node.url.standardizedFileURL == target {
                return true
            }
            if let children = node.children, contains(target, in: children) {
                return true
            }
        }
        return false
    }

    private static func buildTree(
        at directoryURL: URL,
        showHiddenFiles: Bool,
        remaining: inout Int,
        depth: Int,
        isCancelled: () -> Bool
    ) -> [WorkspaceTreeNode] {
        guard remaining > 0, depth < 64, !isCancelled() else { return [] }

        let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else {
            return []
        }

        var nodes: [WorkspaceTreeNode] = []
        for itemURL in contents {
            guard remaining > 0, !isCancelled() else { break }
            guard let values = try? itemURL.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else {
                continue
            }

            let name = itemURL.lastPathComponent
            if !showHiddenFiles && name.hasPrefix(".") {
                continue
            }

            if values.isDirectory == true {
                guard !ignoredDirectories.contains(name) else { continue }
                remaining -= 1
                let children = buildTree(
                    at: itemURL,
                    showHiddenFiles: showHiddenFiles,
                    remaining: &remaining,
                    depth: depth + 1,
                    isCancelled: isCancelled
                )
                nodes.append(WorkspaceTreeNode(
                    name: name,
                    url: itemURL,
                    kind: .folder,
                    children: children
                ))
                continue
            }

            guard values.isRegularFile == true else { continue }
            let fileExtension = itemURL.pathExtension.lowercased()
            let kind: WorkspaceTreeNodeKind
            if editableExtensions.contains(fileExtension) {
                kind = .markdown
            } else if imageExtensions.contains(fileExtension) {
                kind = .image
            } else {
                continue
            }

            remaining -= 1
            nodes.append(WorkspaceTreeNode(
                name: name,
                url: itemURL,
                kind: kind,
                children: nil
            ))
        }

        return nodes.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
