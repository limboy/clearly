import AppKit
import CoreServices
import Foundation
import Observation
import ClearlyCore

/// macOS-only state for Lettera-style "folder as workspace" editing.
///
/// This deliberately stays narrow: one folder, one active Markdown buffer,
/// a file tree, and autosave. It does not index the folder or introduce vault,
/// backlinks, search, sync, or AI infrastructure.
@MainActor
@Observable
final class WorkspaceManager {
    private final class WeakReference {
        weak var manager: WorkspaceManager?

        init(_ manager: WorkspaceManager) {
            self.manager = manager
        }
    }

    private static var managerReferences: [WeakReference] = []
    private static weak var activeManager: WorkspaceManager?
    private static var isTerminating = false

    static var active: WorkspaceManager? {
        if let activeManager, activeManager.hasVisibleWindow {
            return activeManager
        }
        return liveManagers.last(where: \.hasVisibleWindow) ?? liveManagers.last
    }

    static var hasAnyVisibleWindow: Bool {
        liveManagers.contains(where: \.hasVisibleWindow)
    }

    static var mainWindowManager: WorkspaceManager? {
        liveManagers.first(where: { $0.workspaceWindow?.isMainWindow == true })
    }

    static func windowDidBecomeMain(_ window: NSWindow) {
        if let manager = liveManagers.first(where: { $0.workspaceWindow === window }) {
            activeManager = manager
        }
    }

    static func prepareAllForTermination() -> Bool {
        for manager in liveManagers {
            guard manager.prepareForWindowClose() else { return false }
        }
        return true
    }

    static func closeAllWindowsForMenuBar() {
        for manager in liveManagers {
            manager.workspaceWindow?.performClose(nil)
        }
    }

    static func persistOpenWorkspacesForRestoration() {
        guard !isTerminating else { return }
        let bookmarks = liveManagers.compactMap { manager -> Data? in
            guard manager.workspaceWindow != nil else { return nil }
            return manager.restorationBookmarkData
        }
        UserDefaults.standard.set(bookmarks, forKey: sessionBookmarksKey)
    }

    static func beginAppTermination() {
        persistOpenWorkspacesForRestoration()
        isTerminating = true
    }

    static var additionalWorkspaceBookmarksForLaunch: ArraySlice<Data> {
        launchRestorationBookmarks.dropFirst()
    }

    private static var liveManagers: [WorkspaceManager] {
        managerReferences.removeAll(where: { $0.manager == nil })
        return managerReferences.compactMap(\.manager)
    }

    private(set) var rootURL: URL?
    private(set) var tree: [WorkspaceTreeNode] = []
    private(set) var currentFileURL: URL?
    private(set) var isLoadingTree = false
    private(set) var errorMessage: String?
    private(set) var expandedFolderPaths: Set<String>
    private(set) var renamingURL: URL?
    var selectedTreeURL: URL?

    var currentText: String = "" {
        didSet {
            guard !isReplacingDocument else { return }
            scheduleAutoSave()
        }
    }

    var workspaceName: String {
        rootURL?.lastPathComponent ?? "Workspace"
    }

    var currentFileName: String {
        currentFileURL?.lastPathComponent ?? workspaceName
    }

    var hasVisibleWindow: Bool {
        workspaceWindow?.isVisible == true
    }

    @ObservationIgnored private var lastSavedText = ""
    @ObservationIgnored private var isReplacingDocument = false
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    @ObservationIgnored private var treeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var treeGeneration = 0
    @ObservationIgnored private var eventStream: FSEventStreamRef?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private weak var workspaceWindow: NSWindow?
    @ObservationIgnored private(set) var restorationBookmarkData: Data?

    private static let bookmarkKey = "workspaceFolderBookmark"
    private static let sessionBookmarksKey = "workspaceSessionFolderBookmarks"
    private static let expandedPathsKey = "workspaceExpandedFolderPaths"
    private static let autoSaveDelay: TimeInterval = 0.45
    private static let launchRestorationBookmarks: [Data] = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: sessionBookmarksKey) != nil {
            return defaults.array(forKey: sessionBookmarksKey) as? [Data] ?? []
        }
        return defaults.data(forKey: bookmarkKey).map { [$0] } ?? []
    }()

    init(folderURL: URL? = nil, bookmarkData: Data? = nil) {
        expandedFolderPaths = Set(
            UserDefaults.standard.stringArray(forKey: Self.expandedPathsKey) ?? []
        )
        if let bookmarkData {
            if !restoreWorkspace(from: bookmarkData), let folderURL {
                _ = attachWorkspace(at: folderURL)
            }
        } else if let folderURL {
            _ = attachWorkspace(at: folderURL)
        } else {
            restoreWorkspace()
        }
        Self.managerReferences.append(WeakReference(self))
        if Self.activeManager == nil {
            Self.activeManager = self
        }
    }

    deinit {
        pendingSave?.cancel()
        refreshWork?.cancel()
        treeTask?.cancel()
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Folder selection and persistence

    @discardableResult
    func chooseWorkspace() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to use as a Clearly workspace."
        panel.prompt = "Open Workspace"
        if let rootURL {
            panel.directoryURL = rootURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return attachWorkspace(at: url)
    }

    @discardableResult
    func attachWorkspace(at chosenURL: URL) -> Bool {
        let url = chosenURL.standardizedFileURL
        if rootURL?.standardizedFileURL == url {
            refreshTree()
            return true
        }

        guard prepareForWindowClose() else { return false }

        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            setError("Clearly couldn’t remember access to “\(url.lastPathComponent)”.", error)
            return false
        }

        guard url.startAccessingSecurityScopedResource() else {
            setError("Clearly couldn’t access “\(url.lastPathComponent)”.")
            return false
        }

        stopMonitoring()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url
        restorationBookmarkData = bookmarkData

        UserDefaults.standard.set(bookmarkData, forKey: Self.bookmarkKey)
        replaceWorkspaceRoot(with: url)
        Self.persistOpenWorkspacesForRestoration()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }

    private func restoreWorkspace() {
        guard let bookmarkData = Self.launchRestorationBookmarks.first else {
            return
        }

        _ = restoreWorkspace(from: bookmarkData)
    }

    @discardableResult
    private func restoreWorkspace(from bookmarkData: Data) -> Bool {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL

            guard url.startAccessingSecurityScopedResource() else {
                removeLastWorkspaceBookmarkIfMatching(bookmarkData)
                return false
            }

            scopedURL = url
            restorationBookmarkData = bookmarkData
            if isStale,
               let refreshed = try? url.bookmarkData(
                   options: .withSecurityScope,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                restorationBookmarkData = refreshed
                if UserDefaults.standard.data(forKey: Self.bookmarkKey) == bookmarkData {
                    UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
                }
            }
            replaceWorkspaceRoot(with: url)
            return true
        } catch {
            removeLastWorkspaceBookmarkIfMatching(bookmarkData)
            DiagnosticLog.log("Workspace restore failed: \(error.localizedDescription)")
            return false
        }
    }

    private func removeLastWorkspaceBookmarkIfMatching(_ bookmarkData: Data) {
        if UserDefaults.standard.data(forKey: Self.bookmarkKey) == bookmarkData {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
    }

    private func replaceWorkspaceRoot(with url: URL) {
        pendingSave?.cancel()
        pendingSave = nil
        treeTask?.cancel()
        refreshWork?.cancel()
        refreshWork = nil

        isReplacingDocument = true
        rootURL = url
        currentFileURL = nil
        currentText = ""
        lastSavedText = ""
        tree = []
        renamingURL = nil
        selectedTreeURL = nil
        isReplacingDocument = false

        startMonitoring(url)
        refreshTree()
    }

    // MARK: - File loading and saving

    @discardableResult
    func openFile(at chosenURL: URL) -> Bool {
        let url = chosenURL.standardizedFileURL
        guard WorkspaceTreeNode.editableExtensions.contains(url.pathExtension.lowercased()),
              isInsideWorkspace(url) else {
            return false
        }
        if currentFileURL?.standardizedFileURL == url {
            return true
        }

        NotificationCenter.default.post(name: .flushEditorBuffer, object: nil)
        guard saveCurrentFileIfNeeded() else { return false }
        guard Limits.isOpenableSize(url) else {
            setError("“\(url.lastPathComponent)” is too large to open.")
            return false
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let text = String(decoding: data, as: UTF8.self)
            isReplacingDocument = true
            currentFileURL = url
            selectedTreeURL = url
            currentText = text
            lastSavedText = text
            isReplacingDocument = false
            return true
        } catch {
            setError("Clearly couldn’t open “\(url.lastPathComponent)”.", error)
            return false
        }
    }

    /// Flushes the NSTextView’s synchronous buffer and writes the active file.
    /// Returns false when the write failed so callers can keep the window open.
    @discardableResult
    func prepareForWindowClose() -> Bool {
        NotificationCenter.default.post(name: .flushEditorBuffer, object: nil)
        return saveCurrentFileIfNeeded()
    }

    @discardableResult
    private func saveCurrentFileIfNeeded() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard let currentFileURL else { return true }
        guard FileManager.default.fileExists(atPath: currentFileURL.path) else {
            clearCurrentFile()
            return true
        }
        guard currentText != lastSavedText else { return true }

        do {
            try Data(currentText.utf8).write(to: currentFileURL, options: .atomic)
            lastSavedText = currentText
            return true
        } catch {
            setError("Clearly couldn’t save “\(currentFileURL.lastPathComponent)”.", error)
            return false
        }
    }

    private func scheduleAutoSave() {
        pendingSave?.cancel()
        guard currentFileURL != nil, currentText != lastSavedText else {
            pendingSave = nil
            return
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                _ = self?.saveCurrentFileIfNeeded()
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoSaveDelay, execute: work)
    }

    // MARK: - Creating workspace items

    @discardableResult
    func createNewFile(in folder: URL? = nil) -> URL? {
        guard prepareForWindowClose(),
              let rootURL else {
            return nil
        }
        let targetFolder = folder?.standardizedFileURL ?? rootURL
        guard isInsideWorkspace(targetFolder) else { return nil }

        let fileURL = nextUntitledFileURL(in: targetFolder)
        do {
            try Data().write(to: fileURL, options: .atomic)
            setFolderExpanded(true, for: targetFolder)
            refreshTree()
            _ = openFile(at: fileURL)
            return fileURL
        } catch {
            setError("Clearly couldn’t create a file in “\(targetFolder.lastPathComponent)”.", error)
            return nil
        }
    }

    func beginCreatingNewFolder(in folder: URL? = nil) {
        guard let rootURL else { return }
        let targetFolder = folder?.standardizedFileURL ?? rootURL
        guard isInsideWorkspace(targetFolder),
              (try? targetFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return
        }

        let newFolderURL = nextUntitledFolderURL(in: targetFolder)
        do {
            try FileManager.default.createDirectory(
                at: newFolderURL,
                withIntermediateDirectories: false
            )
            setFolderExpanded(true, for: targetFolder)
            selectedTreeURL = newFolderURL
            renamingURL = newFolderURL
            refreshTree()
        } catch {
            setError("Clearly couldn’t create a folder in “\(targetFolder.lastPathComponent)”.", error)
        }
    }

    // MARK: - Renaming workspace items

    @discardableResult
    func beginRenaming(_ chosenURL: URL) -> Bool {
        let url = chosenURL.standardizedFileURL
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let isEditableFile =
            WorkspaceTreeNode.editableExtensions.contains(url.pathExtension.lowercased())
        guard renamingURL == nil,
              (isDirectory || isEditableFile),
              isInsideWorkspace(url),
              url != rootURL?.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        renamingURL = url
        return true
    }

    func isRenaming(_ url: URL) -> Bool {
        renamingURL?.standardizedFileURL == url.standardizedFileURL
    }

    @discardableResult
    func renameItem(at chosenURL: URL, to proposedName: String) -> URL? {
        let url = chosenURL.standardizedFileURL
        guard isRenaming(url), isInsideWorkspace(url) else { return nil }

        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            setError("That name isn’t valid.")
            return nil
        }

        let destinationName: String
        if isDirectory {
            destinationName = name
        } else {
            let fileExtension = url.pathExtension
            let extensionSuffix = ".\(fileExtension)"
            destinationName = name.lowercased().hasSuffix(extensionSuffix.lowercased())
                ? name
                : name + extensionSuffix
        }

        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(destinationName, isDirectory: isDirectory)
            .standardizedFileURL
        if destination == url {
            renamingURL = nil
            return url
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            setError("A file or folder named “\(destinationName)” already exists.")
            return nil
        }

        if let currentFileURL,
           isSameOrDescendant(currentFileURL, of: url) {
            NotificationCenter.default.post(name: .flushEditorBuffer, object: nil)
            guard saveCurrentFileIfNeeded() else { return nil }
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
            if let currentFileURL,
               let updatedFileURL = rebasedURL(currentFileURL, from: url, to: destination) {
                self.currentFileURL = updatedFileURL
            }
            if let selectedTreeURL,
               let updatedSelection = rebasedURL(selectedTreeURL, from: url, to: destination) {
                self.selectedTreeURL = updatedSelection
            }
            if isDirectory {
                rebaseExpandedFolderPaths(from: url, to: destination)
            }
            renamingURL = nil
            refreshTree()
            return destination
        } catch {
            setError("Clearly couldn’t rename “\(url.lastPathComponent)”.", error)
            return nil
        }
    }

    func cancelRenaming(_ url: URL) {
        guard isRenaming(url) else { return }
        renamingURL = nil
    }

    private func nextUntitledFileURL(in folder: URL) -> URL {
        var number = 1
        while true {
            let name = number == 1 ? "Untitled.md" : "Untitled \(number).md"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            number += 1
        }
    }

    private func nextUntitledFolderURL(in folder: URL) -> URL {
        var number = 1
        while true {
            let name = number == 1 ? "untitled folder" : "untitled folder \(number)"
            let candidate = folder.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            number += 1
        }
    }

    func moveToTrash(_ chosenURL: URL) {
        let url = chosenURL.standardizedFileURL
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let isEditableFile =
            WorkspaceTreeNode.editableExtensions.contains(url.pathExtension.lowercased())
        guard (isDirectory || isEditableFile),
              isInsideWorkspace(url),
              url != rootURL?.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        if let currentFileURL,
           isSameOrDescendant(currentFileURL, of: url) {
            NotificationCenter.default.post(name: .flushEditorBuffer, object: nil)
            guard saveCurrentFileIfNeeded() else { return }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let trashedURLs = try await NSWorkspace.shared.recycle([url])
                guard trashedURLs[url] != nil else {
                    self.setError("Clearly couldn’t move “\(url.lastPathComponent)” to Trash.")
                    return
                }
                if let currentFileURL = self.currentFileURL,
                   self.isSameOrDescendant(currentFileURL, of: url) {
                    self.clearCurrentFile()
                }
                if let renamingURL = self.renamingURL,
                   self.isSameOrDescendant(renamingURL, of: url) {
                    self.renamingURL = nil
                }
                if let selectedTreeURL = self.selectedTreeURL,
                   self.isSameOrDescendant(selectedTreeURL, of: url) {
                    self.selectedTreeURL = self.currentFileURL
                }
                if isDirectory {
                    self.removeExpandedFolderPaths(inside: url)
                }
                self.refreshTree()
            } catch {
                self.setError(
                    "Clearly couldn’t move “\(url.lastPathComponent)” to Trash.",
                    error
                )
            }
        }
    }

    // MARK: - Sidebar state

    func isFolderExpanded(_ url: URL) -> Bool {
        expandedFolderPaths.contains(url.standardizedFileURL.path)
    }

    func setFolderExpanded(_ expanded: Bool, for url: URL) {
        let path = url.standardizedFileURL.path
        if expanded {
            expandedFolderPaths.insert(path)
        } else {
            expandedFolderPaths.remove(path)
        }
        UserDefaults.standard.set(Array(expandedFolderPaths), forKey: Self.expandedPathsKey)
    }

    func revealInFinder(_ url: URL? = nil) {
        guard let target = url ?? rootURL else { return }
        if target == rootURL {
            NSWorkspace.shared.open(target)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Tree loading

    func refreshTree() {
        guard let rootURL else { return }
        treeGeneration += 1
        let generation = treeGeneration
        treeTask?.cancel()
        isLoadingTree = true

        treeTask = Task.detached(priority: .userInitiated) {
            let isCancelled = {
                withUnsafeCurrentTask { $0?.isCancelled ?? false }
            }
            let nodes = WorkspaceTreeNode.buildTree(
                at: rootURL,
                isCancelled: isCancelled
            )
            guard !isCancelled() else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.treeGeneration == generation,
                      self.rootURL?.standardizedFileURL == rootURL.standardizedFileURL else {
                    return
                }
                self.tree = nodes
                self.clearCurrentFileIfDeleted()
                self.isLoadingTree = false
            }
        }
    }

    private func scheduleTreeRefresh() {
        clearCurrentFileIfDeleted()
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshWork = nil
                self?.refreshTree()
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Workspace window coordination

    func registerWindow(_ window: NSWindow) {
        workspaceWindow = window
        Self.activeManager = self
        Self.persistOpenWorkspacesForRestoration()
    }

    func unregisterWindow(_ window: NSWindow) {
        if workspaceWindow === window {
            workspaceWindow = nil
            if Self.activeManager === self {
                Self.activeManager = Self.liveManagers.last(where: \.hasVisibleWindow)
            }
            Self.persistOpenWorkspacesForRestoration()
        }
    }

    // MARK: - FSEvents

    private func startMonitoring(_ rootURL: URL) {
        stopMonitoring()

        var context = FSEventStreamContext()
        let info = Unmanaged.passRetained(WorkspaceFSStreamInfo(manager: self))
        context.info = info.toOpaque()
        context.release = { rawInfo in
            guard let rawInfo else { return }
            Unmanaged<WorkspaceFSStreamInfo>.fromOpaque(rawInfo).release()
        }

        guard let stream = FSEventStreamCreate(
            nil,
            { _, rawInfo, _, _, _, _ in
                guard let rawInfo else { return }
                let info = Unmanaged<WorkspaceFSStreamInfo>
                    .fromOpaque(rawInfo)
                    .takeUnretainedValue()
                DispatchQueue.main.async { [weak manager = info.manager] in
                    manager?.scheduleTreeRefresh()
                }
            },
            &context,
            [rootURL.path as CFString] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopMonitoring() {
        refreshWork?.cancel()
        refreshWork = nil
        guard let eventStream else { return }
        FSEventStreamStop(eventStream)
        FSEventStreamInvalidate(eventStream)
        FSEventStreamRelease(eventStream)
        self.eventStream = nil
    }

    // MARK: - Helpers

    private func isInsideWorkspace(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func isSameOrDescendant(_ url: URL, of ancestorURL: URL) -> Bool {
        let ancestorPath = ancestorURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == ancestorPath || path.hasPrefix(ancestorPath + "/")
    }

    private func removeExpandedFolderPaths(inside folderURL: URL) {
        let folderPath = folderURL.standardizedFileURL.path
        expandedFolderPaths = Set(expandedFolderPaths.filter {
            $0 != folderPath && !$0.hasPrefix(folderPath + "/")
        })
        UserDefaults.standard.set(Array(expandedFolderPaths), forKey: Self.expandedPathsKey)
    }

    private func rebaseExpandedFolderPaths(from oldURL: URL, to newURL: URL) {
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        expandedFolderPaths = Set(expandedFolderPaths.map { path in
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return path }
            return newPath + path.dropFirst(oldPath.count)
        })
        UserDefaults.standard.set(Array(expandedFolderPaths), forKey: Self.expandedPathsKey)
    }

    private func rebasedURL(_ url: URL, from oldURL: URL, to newURL: URL) -> URL? {
        guard isSameOrDescendant(url, of: oldURL) else { return nil }
        let oldPath = oldURL.standardizedFileURL.path
        let suffix = url.standardizedFileURL.path.dropFirst(oldPath.count)
        return URL(fileURLWithPath: newURL.standardizedFileURL.path + suffix)
    }

    private func clearCurrentFileIfDeleted() {
        guard let currentFileURL,
              !FileManager.default.fileExists(atPath: currentFileURL.path) else {
            return
        }
        clearCurrentFile()
    }

    private func clearCurrentFile() {
        pendingSave?.cancel()
        pendingSave = nil
        isReplacingDocument = true
        currentFileURL = nil
        currentText = ""
        lastSavedText = ""
        isReplacingDocument = false
    }

    private func setError(_ message: String, _ error: Error? = nil) {
        errorMessage = error.map { "\(message)\n\n\($0.localizedDescription)" } ?? message
        DiagnosticLog.log("Workspace error: \(errorMessage ?? message)")
    }
}

private final class WorkspaceFSStreamInfo {
    weak var manager: WorkspaceManager?

    init(manager: WorkspaceManager) {
        self.manager = manager
    }
}
