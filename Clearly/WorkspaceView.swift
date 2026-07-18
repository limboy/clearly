import AppKit
import SwiftUI
import ClearlyCore

enum WorkspaceScene {
    static let id = "workspace"

    struct Value: Codable, Hashable {
        let id: UUID
        let folderURL: URL?

        init(folderURL: URL?) {
            id = UUID()
            self.folderURL = folderURL
        }
    }
}

private struct WorkspaceManagerFocusedKey: FocusedValueKey {
    typealias Value = WorkspaceManager
}

extension FocusedValues {
    var workspaceManager: WorkspaceManager? {
        get { self[WorkspaceManagerFocusedKey.self] }
        set { self[WorkspaceManagerFocusedKey.self] = newValue }
    }
}



/// A macOS workspace window: a persistent folder tree on the left and
/// Clearly's existing editor/preview surface on the right.
struct WorkspaceView: View {
    @State private var workspace: WorkspaceManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var outlineState = OutlineState()
    @State private var currentViewMode: ViewMode = .edit

    init(folderURL: URL? = nil) {
        _workspace = State(initialValue: WorkspaceManager(folderURL: folderURL))
    }

    var body: some View {
        @Bindable var workspace = workspace

        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                WorkspaceSidebar(workspace: workspace)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 360)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                if workspace.currentFileURL != nil {
                    ContentView(
                        text: $workspace.currentText,
                        fileURL: workspace.currentFileURL,
                        outlineState: outlineState,
                        embedsOutline: false,
                        minimumContentWidth: 400,
                        onViewModeChange: { currentViewMode = $0 }
                    )
                } else {
                    WorkspaceEmptyDetail(workspace: workspace)
                }
            }
            .navigationTitle(workspace.currentFileName)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if outlineState.isVisible {
                OutlineView(
                    outlineState: outlineState,
                    isEditorVisible: currentViewMode == .edit
                )
                .frame(width: OutlineView.width)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(WorkspaceWindowObserver(workspace: workspace))
        .focusedSceneValue(\.workspaceManager, workspace)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert(
            "Workspace Error",
            isPresented: Binding(
                get: { workspace.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        workspace.dismissError()
                    }
                }
            )
        ) {
            Button("OK") {
                workspace.dismissError()
            }
        } message: {
            Text(workspace.errorMessage ?? "")
        }
        .onDisappear {
            _ = workspace.prepareForWindowClose()
        }
    }
}

private struct WorkspaceSidebar: View {
    @Bindable var workspace: WorkspaceManager
    @State private var selectedFileURL: URL?
    @State private var pendingScrollURL: URL?
    @State private var pendingManualSelectionURL: URL?

    private var treeSelection: Binding<URL?> {
        Binding(
            get: { selectedFileURL },
            set: { newURL in
                selectedFileURL = newURL
                workspace.selectedTreeURL = newURL?.standardizedFileURL
            }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: treeSelection) {
                Section {
                    ForEach(workspace.tree) { node in
                        WorkspaceSidebarNode(
                            node: node,
                            workspace: workspace,
                            onRenamed: { renamedURL in
                                selectedFileURL = renamedURL
                                requestScroll(to: renamedURL, using: proxy)
                            }
                        )
                    }

                } header: {
                    HStack(spacing: 6) {
                        Text(workspace.workspaceName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if workspace.isLoadingTree {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .textCase(nil)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBackgroundSwiftUI)
            .contextMenu {
                Button("New File", systemImage: "doc.badge.plus") {
                    workspace.createNewFile()
                }
                Button("New Folder", systemImage: "folder.badge.plus") {
                    workspace.beginCreatingNewFolder()
                }
            }
            .onKeyPress(.return) {
                guard workspace.renamingURL == nil,
                      let selectedFileURL,
                      workspace.beginRenaming(selectedFileURL) else {
                    return .ignored
                }
                return .handled
            }
            .onAppear {
                selectedFileURL = workspace.currentFileURL
                workspace.selectedTreeURL = workspace.currentFileURL
            }
            .onChange(of: selectedFileURL) { oldURL, newURL in
                workspace.selectedTreeURL = newURL?.standardizedFileURL
                guard let newURL,
                      newURL.standardizedFileURL
                        != workspace.currentFileURL?.standardizedFileURL else {
                    return
                }
                if (try? newURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    pendingManualSelectionURL = nil
                    return
                }
                pendingManualSelectionURL = newURL.standardizedFileURL
                DispatchQueue.main.async {
                    if !workspace.openFile(at: newURL) {
                        pendingManualSelectionURL = nil
                        selectedFileURL = oldURL
                    }
                }
            }
            .onChange(of: workspace.currentFileURL) { _, newURL in
                let wasSelectedManually = newURL.map {
                    $0.standardizedFileURL == pendingManualSelectionURL
                } ?? false
                pendingManualSelectionURL = nil
                let targetSelection = workspace.selectedTreeURL ?? newURL
                if selectedFileURL?.standardizedFileURL
                    != targetSelection?.standardizedFileURL {
                    selectedFileURL = targetSelection
                }
                if !wasSelectedManually {
                    requestScroll(to: targetSelection, using: proxy)
                }
            }
            .onChange(of: workspace.tree) { _, _ in
                if let selectedFileURL,
                   !WorkspaceTreeNode.contains(selectedFileURL, in: workspace.tree) {
                    let fallbackURL = workspace.currentFileURL.flatMap {
                        WorkspaceTreeNode.contains($0, in: workspace.tree) ? $0 : nil
                    }
                    self.selectedFileURL = fallbackURL
                    workspace.selectedTreeURL = fallbackURL
                    requestScroll(to: fallbackURL, using: proxy)
                }
                guard let pendingScrollURL else { return }
                requestScroll(to: pendingScrollURL, using: proxy)
            }
            .onChange(of: workspace.selectedTreeURL) { _, newURL in
                guard let newURL else { return }
                if selectedFileURL?.standardizedFileURL != newURL.standardizedFileURL {
                    selectedFileURL = newURL
                }
                requestScroll(to: newURL, using: proxy)
            }
        }
    }

    private func requestScroll(to url: URL?, using proxy: ScrollViewProxy) {
        guard let target = url?.standardizedFileURL else {
            pendingScrollURL = nil
            return
        }
        guard WorkspaceTreeNode.contains(target, in: workspace.tree) else {
            pendingScrollURL = target
            return
        }

        pendingScrollURL = nil
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }


}

private struct WorkspaceSidebarNode: View {
    let node: WorkspaceTreeNode
    @Bindable var workspace: WorkspaceManager
    let onRenamed: (URL) -> Void

    var body: some View {
        if node.isDirectory {
            if node.displayChildren != nil {
                DisclosureGroup(isExpanded: expandedBinding) {
                    ForEach(node.children ?? []) { child in
                        WorkspaceSidebarNode(
                            node: child,
                            workspace: workspace,
                            onRenamed: onRenamed
                        )
                    }
                } label: {
                    nodeLabel
                }
                .tag(node.url)
                .contextMenu { folderContextMenu }
            } else {
                nodeLabel
                    .tag(node.url)
                    .contextMenu { folderContextMenu }
            }
        } else if node.isEditable {
            nodeLabel
                .tag(node.url)
                .contextMenu {
                    creationContextMenu
                    Divider()
                    Button("Reveal in Finder", systemImage: "folder") {
                        workspace.revealInFinder(node.url)
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        CopyActions.copyFilePath(node.url)
                    }
                    Divider()
                    Button("Move To Trash", systemImage: "trash") {
                        workspace.moveToTrash(node.url)
                    }
                }
        } else {
            nodeLabel
                .opacity(0.48)
                .contextMenu {
                    creationContextMenu
                    Divider()
                    Button("Reveal in Finder", systemImage: "folder") {
                        workspace.revealInFinder(node.url)
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        CopyActions.copyFilePath(node.url)
                    }
                }
        }
    }

    @ViewBuilder
    private var nodeLabel: some View {
        if workspace.isRenaming(node.url) {
            WorkspaceRenameRow(
                node: node,
                workspace: workspace,
                onRenamed: onRenamed
            )
        } else {
            WorkspaceSidebarLabel(node: node)
        }
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { workspace.isFolderExpanded(node.url) },
            set: { workspace.setFolderExpanded($0, for: node.url) }
        )
    }

    @ViewBuilder
    private var folderContextMenu: some View {
        Button("New File", systemImage: "doc.badge.plus") {
            workspace.createNewFile(in: node.url)
        }
        Button("New Folder", systemImage: "folder.badge.plus") {
            workspace.beginCreatingNewFolder(in: node.url)
        }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") {
            workspace.revealInFinder(node.url)
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            CopyActions.copyFilePath(node.url)
        }
        Divider()
        Button("Move To Trash", systemImage: "trash") {
            workspace.moveToTrash(node.url)
        }
    }

    @ViewBuilder
    private var creationContextMenu: some View {
        Button("New File", systemImage: "doc.badge.plus") {
            workspace.createNewFile(in: node.url.deletingLastPathComponent())
        }
        Button("New Folder", systemImage: "folder.badge.plus") {
            workspace.beginCreatingNewFolder(in: node.url.deletingLastPathComponent())
        }
    }
}

private struct WorkspaceRenameRow: View {
    let node: WorkspaceTreeNode
    @Bindable var workspace: WorkspaceManager
    let onRenamed: (URL) -> Void
    @State private var name: String
    @FocusState private var isNameFieldFocused: Bool

    init(
        node: WorkspaceTreeNode,
        workspace: WorkspaceManager,
        onRenamed: @escaping (URL) -> Void
    ) {
        self.node = node
        self.workspace = workspace
        self.onRenamed = onRenamed
        _name = State(initialValue: node.displayName)
    }

    var body: some View {
        Label {
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.Typography.sidebarRow)
                .focused($isNameFieldFocused)
                .onSubmit {
                    submit()
                }
                .onExitCommand {
                    workspace.cancelRenaming(node.url)
                }
                .onChange(of: isNameFieldFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused {
                        submit()
                    }
                }
        } icon: {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(Theme.accentColorSwiftUI)
        }
        .frame(minHeight: 20)
        .onAppear {
            DispatchQueue.main.async {
                isNameFieldFocused = true
            }
        }
        .onChange(of: workspace.errorMessage) { previousError, error in
            guard previousError != nil,
                  error == nil,
                  workspace.isRenaming(node.url) else {
                return
            }
            DispatchQueue.main.async {
                isNameFieldFocused = true
            }
        }
    }

    private func submit() {
        guard workspace.isRenaming(node.url),
              let renamedURL = workspace.renameItem(at: node.url, to: name) else {
            return
        }
        onRenamed(renamedURL)
    }
}


private struct WorkspaceSidebarLabel: View {
    let node: WorkspaceTreeNode

    var body: some View {
        Label {
            Text(node.displayName)
                .font(Theme.Typography.sidebarRow)
                .lineLimit(1)
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
        .frame(minHeight: 20)
        .id(node.url.standardizedFileURL)
    }

    private var iconName: String {
        switch node.kind {
        case .folder:
            return "folder.fill"
        case .markdown:
            return "doc.text"
        case .image:
            return "photo"
        }
    }

    private var iconColor: Color {
        switch node.kind {
        case .folder, .markdown:
            return Theme.accentColorSwiftUI
        case .image:
            return Theme.textColorSwiftUI.opacity(0.45)
        }
    }
}

private struct WorkspaceEmptyDetail: View {
    @Bindable var workspace: WorkspaceManager
    @State private var isDropTargeted = false

    @ViewBuilder
    var body: some View {
        if workspace.rootURL == nil {
            workspaceChooser
        } else if workspace.isLoadingTree {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if WorkspaceTreeNode.firstEditableFile(in: workspace.tree) != nil {
            noFileSelected
        } else {
            noMarkdownFiles
        }
    }

    @ViewBuilder
    private var workspaceChooser: some View {
        if #available(macOS 26.0, *) {
            workspaceChooserContent
                .dropDestination(for: URL.self) { urls, _ in
                    _ = attachFirstFolder(from: urls)
                }
        } else {
            workspaceChooserContent
                .dropDestination(for: URL.self) { urls, _ in
                    attachFirstFolder(from: urls)
                } isTargeted: {
                    isDropTargeted = $0
                }
        }
    }

    private var workspaceChooserContent: some View {
        ContentUnavailableView {
            Label(
                "Open a Workspace",
                systemImage: isDropTargeted ? "folder.fill.badge.plus" : "folder.badge.plus"
            )
        } description: {
            Text("Drag a folder here, or choose one to browse and edit its Markdown files.")
        } actions: {
            Button("Open Folder…") {
                workspace.chooseWorkspace()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Theme.accentColorSwiftUI.opacity(0.08) : Color.clear)
    }

    private var noFileSelected: some View {
        ContentUnavailableView {
            Label("No File Selected", systemImage: "doc.text")
        } description: {
            Text("Select a Markdown file in the sidebar, or create a new one.")
        }
    }

    private var noMarkdownFiles: some View {
        ContentUnavailableView {
            Label("No Markdown Files", systemImage: "doc.text")
        } description: {
            Text("Create a Markdown file in this folder to get started.")
        } actions: {
            Button("New File") {
                workspace.createNewFile()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func attachFirstFolder(from urls: [URL]) -> Bool {
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            return workspace.attachWorkspace(at: url)
        }
        return false
    }
}

/// Captures the SwiftUI-owned workspace window without taking over its delegate.
struct WorkspaceWindowObserver: NSViewRepresentable {
    let workspace: WorkspaceManager

    final class Holder: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
        private static let newFileItemIdentifier = NSToolbarItem.Identifier(
            "com.sabotage.clearly.workspace.newFile"
        )

        weak var window: NSWindow?
        weak var workspace: WorkspaceManager?
        private let toolbar = NSToolbar(
            identifier: NSToolbar.Identifier("workspace.\(UUID().uuidString)")
        )
        private var windowUpdateObserver: NSObjectProtocol?

        init(workspace: WorkspaceManager) {
            self.workspace = workspace
            super.init()
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
        }

        deinit {
            if let windowUpdateObserver {
                NotificationCenter.default.removeObserver(windowUpdateObserver)
            }
        }

        func installToolbar(in window: NSWindow) {
            if self.window !== window {
                if let windowUpdateObserver {
                    NotificationCenter.default.removeObserver(windowUpdateObserver)
                }
                self.window = window
                windowUpdateObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification,
                    object: window,
                    queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window else { return }
                    self.installToolbarIfNeeded(in: window)
                }
            }

            installToolbarIfNeeded(in: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.installToolbarIfNeeded(in: window)
            }
        }

        private func installToolbarIfNeeded(in window: NSWindow) {
            guard window.toolbar !== toolbar else {
                toolbar.validateVisibleItems()
                return
            }
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [
                .flexibleSpace,
                Self.newFileItemIdentifier,
                .toggleSidebar,
                .sidebarTrackingSeparator,
            ]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            guard itemIdentifier == Self.newFileItemIdentifier else { return nil }

            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New File"
            item.paletteLabel = "New File"
            item.toolTip = "New File"
            item.image = NSImage(
                systemSymbolName: "plus",
                accessibilityDescription: "New File"
            )
            item.target = self
            item.action = #selector(createNewFile(_:))
            item.isBordered = true
            item.visibilityPriority = .high
            return item
        }

        func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
            item.itemIdentifier != Self.newFileItemIdentifier || workspace?.rootURL != nil
        }

        @MainActor @objc private func createNewFile(_ sender: NSToolbarItem) {
            workspace?.createNewFile()
        }
    }

    func makeCoordinator() -> Holder { Holder(workspace: workspace) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(from: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        register(from: nsView, context: context)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Holder) {
        guard let window = coordinator.window,
              let workspace = coordinator.workspace else {
            return
        }
        workspace.unregisterWindow(window)
    }

    private func register(from view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.installToolbar(in: window)
            workspace.registerWindow(window)
        }
    }
}

struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceManager) private var focusedWorkspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New In Window", systemImage: "plus") {
                ClearlyAppDelegate.shared?.ensureRegularAndActivate()
                NSDocumentController.shared.newDocument(nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Button("Open…") {
                openFileOrWorkspace()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .saveItem) {
            Button("Move To Trash", systemImage: "trash") {
                guard let workspace = focusedWorkspace,
                      let targetURL = workspace.selectedTreeURL ?? workspace.currentFileURL else {
                    return
                }
                workspace.moveToTrash(targetURL)
            }
        }
    }

    private func openFileOrWorkspace() {
        ClearlyAppDelegate.shared?.ensureRegularAndActivate()

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = MarkdownDocument.readableContentTypes
        panel.message = "Choose a Markdown file or a folder to open as a workspace."
        panel.prompt = "Open"
        panel.directoryURL = activeWorkspace?.rootURL

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory {
            if let activeWorkspace, activeWorkspace.rootURL == nil {
                _ = activeWorkspace.attachWorkspace(at: url)
            } else {
                openWindow(
                    id: WorkspaceScene.id,
                    value: WorkspaceScene.Value(folderURL: url)
                )
            }
            return
        }

        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                NSAlert(error: error).runModal()
            }
        }
    }

    private var activeWorkspace: WorkspaceManager? {
        focusedWorkspace ?? WorkspaceManager.active
    }
}
