import Foundation

public enum WorkspaceSearchScope: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case title = "Title"
    case content = "Content"

    public var id: String { rawValue }
}

public enum WorkspaceSearchResultMatchKind: Sendable, Hashable, Equatable {
    case title
    case content(line: Int, snippet: String)
}

public struct WorkspaceSearchResult: Identifiable, Sendable, Hashable, Equatable {
    public let id: String
    public let url: URL
    public let title: String
    public let relativePath: String
    public let matchKind: WorkspaceSearchResultMatchKind

    public init(
        url: URL,
        title: String,
        relativePath: String,
        matchKind: WorkspaceSearchResultMatchKind
    ) {
        self.url = url
        self.title = title
        self.relativePath = relativePath
        self.matchKind = matchKind
        switch matchKind {
        case .title:
            self.id = "\(url.path)#title"
        case .content(let line, _):
            self.id = "\(url.path)#L\(line)"
        }
    }
}

public struct WorkspaceSearchEngine: Sendable {
    public init() {}

    /// Performs a search across editable files in `nodes`.
    /// - Parameters:
    ///   - query: The search string.
    ///   - scope: The search scope (`.all`, `.title`, or `.content`).
    ///   - nodes: List of `WorkspaceTreeNode` representing the workspace structure.
    ///   - rootURL: The root directory URL for computing relative paths.
    ///   - maxResults: Maximum number of search results to return (default 50).
    ///   - maxFileSizeBytes: Skips content search for files larger than this limit (default 2MB).
    /// - Returns: List of `WorkspaceSearchResult`.
    public static func search(
        query: String,
        scope: WorkspaceSearchScope = .all,
        in nodes: [WorkspaceTreeNode],
        rootURL: URL?,
        maxResults: Int = 50,
        maxFileSizeBytes: Int64 = 2_000_000
    ) async -> [WorkspaceSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let files = collectEditableFiles(from: nodes)
        guard !files.isEmpty else { return [] }

        var results: [WorkspaceSearchResult] = []
        let lowerQuery = trimmedQuery.lowercased()
        let rootPath = rootURL?.standardizedFileURL.path ?? ""

        for file in files {
            if Task.isCancelled { break }
            guard results.count < maxResults else { break }

            let fileURL = file.url.standardizedFileURL
            let fileName = file.displayName
            let fullPath = fileURL.path
            let relativePath: String
            if !rootPath.isEmpty && fullPath.hasPrefix(rootPath) {
                var rel = String(fullPath.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
                relativePath = rel
            } else {
                relativePath = fileURL.lastPathComponent
            }

            // 1. Check title match if scope allows title
            if scope == .all || scope == .title {
                let titleMatched = fileName.lowercased().contains(lowerQuery) || relativePath.lowercased().contains(lowerQuery)
                if titleMatched {
                    results.append(WorkspaceSearchResult(
                        url: fileURL,
                        title: fileName,
                        relativePath: relativePath,
                        matchKind: .title
                    ))
                }
            }

            // 2. Check content match if scope allows content and file size is under limit
            if (scope == .all || scope == .content) && results.count < maxResults,
               let attr = try? FileManager.default.attributesOfItem(atPath: fullPath),
               let size = attr[.size] as? Int64, size <= maxFileSizeBytes,
               let content = try? String(contentsOf: fileURL, encoding: .utf8) {

                let lines = content.components(separatedBy: .newlines)
                for (index, lineText) in lines.enumerated() {
                    if Task.isCancelled { break }
                    guard results.count < maxResults else { break }

                    if let range = lineText.range(of: trimmedQuery, options: .caseInsensitive) {
                        let snippet = formatSnippet(line: lineText, matchRange: range)
                        let matchKind = WorkspaceSearchResultMatchKind.content(line: index + 1, snippet: snippet)
                        results.append(WorkspaceSearchResult(
                            url: fileURL,
                            title: fileName,
                            relativePath: relativePath,
                            matchKind: matchKind
                        ))
                    }
                }
            }
        }

        return results
    }

    public static func collectEditableFiles(from nodes: [WorkspaceTreeNode]) -> [WorkspaceTreeNode] {
        var result: [WorkspaceTreeNode] = []
        for node in nodes {
            if node.isEditable {
                result.append(node)
            } else if node.isDirectory, let children = node.children {
                result.append(contentsOf: collectEditableFiles(from: children))
            }
        }
        return result
    }

    private static func formatSnippet(line: String, matchRange: Range<String.Index>) -> String {
        let maxSnippetLength = 90
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.count > maxSnippetLength else {
            return trimmedLine
        }

        let matchOffset = trimmedLine.distance(from: trimmedLine.startIndex, to: matchRange.lowerBound)
        let startOffset = max(0, matchOffset - 30)
        let startIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: startOffset)
        let endOffset = min(trimmedLine.count, startOffset + maxSnippetLength)
        let endIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: endOffset)

        var snippet = String(trimmedLine[startIndex..<endIndex])
        if startOffset > 0 { snippet = "…" + snippet }
        if endOffset < trimmedLine.count { snippet = snippet + "…" }
        return snippet
    }
}
