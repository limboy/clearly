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

    static var active: WorkspaceManager? {
        if let activeManager, activeManager.hasVisibleWindow {
            return activeManager
        }
        return liveManagers.last(where: \.hasVisibleWindow) ?? liveManagers.last
    }

    static var hasAnyVisibleWindow: Bool {
        liveManagers.contains(where: \.hasVisibleWindow)
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
        currentFileURL?.lastPathComponent ?? "Workspace"
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

    private static let bookmarkKey = "workspaceFolderBookmark"
    private static let expandedPathsKey = "workspaceExpandedFolderPaths"
    private static let autoSaveDelay: TimeInterval = 0.45

    init(folderURL: URL? = nil) {
        expandedFolderPaths = Set(
            UserDefaults.standard.stringArray(forKey: Self.expandedPathsKey) ?? []
        )
        if let folderURL {
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

        UserDefaults.standard.set(bookmarkData, forKey: Self.bookmarkKey)
        replaceWorkspaceRoot(with: url)
        return true
    }

    private func restoreWorkspace() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL

            guard url.startAccessingSecurityScopedResource() else {
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
                return
            }

            scopedURL = url
            if isStale,
               let refreshed = try? url.bookmarkData(
                   options: .withSecurityScope,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            }
            replaceWorkspaceRoot(with: url)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            DiagnosticLog.log("Workspace restore failed: \(error.localizedDescription)")
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

    func promptForNewFolder(in folder: URL? = nil) {
        guard let rootURL else { return }
        let targetFolder = folder?.standardizedFileURL ?? rootURL
        guard isInsideWorkspace(targetFolder) else { return }

        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the folder."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: "")
        field.placeholderString = "Folder name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            setError("That folder name isn’t valid.")
            return
        }

        let newFolder = targetFolder.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: newFolder.path) else {
            setError("A file or folder named “\(name)” already exists.")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: newFolder,
                withIntermediateDirectories: false
            )
            setFolderExpanded(true, for: targetFolder)
            refreshTree()
        } catch {
            setError("Clearly couldn’t create “\(name)”.", error)
        }
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
    }

    func unregisterWindow(_ window: NSWindow) {
        if workspaceWindow === window {
            workspaceWindow = nil
            if Self.activeManager === self {
                Self.activeManager = Self.liveManagers.last(where: \.hasVisibleWindow)
            }
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
