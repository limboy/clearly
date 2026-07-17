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

    var body: some View {
        List(selection: $selectedFileURL) {
            Section {
                ForEach(workspace.tree) { node in
                    WorkspaceSidebarNode(node: node, workspace: workspace)
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
        .onAppear {
            selectedFileURL = workspace.currentFileURL
        }
        .onChange(of: selectedFileURL) { oldURL, newURL in
            guard let newURL,
                  newURL.standardizedFileURL != workspace.currentFileURL?.standardizedFileURL else {
                return
            }
            DispatchQueue.main.async {
                if !workspace.openFile(at: newURL) {
                    selectedFileURL = oldURL
                }
            }
        }
        .onChange(of: workspace.currentFileURL) { _, newURL in
            if selectedFileURL?.standardizedFileURL != newURL?.standardizedFileURL {
                selectedFileURL = newURL
            }
        }
    }
}

private struct WorkspaceSidebarNode: View {
    let node: WorkspaceTreeNode
    @Bindable var workspace: WorkspaceManager

    var body: some View {
        if node.isDirectory {
            if let children = node.displayChildren {
                DisclosureGroup(isExpanded: expandedBinding) {
                    ForEach(children) { child in
                        WorkspaceSidebarNode(node: child, workspace: workspace)
                    }
                } label: {
                    WorkspaceSidebarLabel(node: node)
                }
                .contextMenu { folderContextMenu }
            } else {
                WorkspaceSidebarLabel(node: node)
                    .contextMenu { folderContextMenu }
            }
        } else if node.isEditable {
            WorkspaceSidebarLabel(node: node)
                .tag(node.url)
                .contextMenu {
                    Button("Reveal in Finder", systemImage: "folder") {
                        workspace.revealInFinder(node.url)
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        CopyActions.copyFilePath(node.url)
                    }
                }
        } else {
            WorkspaceSidebarLabel(node: node)
                .opacity(0.48)
                .contextMenu {
                    Button("Reveal in Finder", systemImage: "folder") {
                        workspace.revealInFinder(node.url)
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        CopyActions.copyFilePath(node.url)
                    }
                }
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
        Button("New Folder…", systemImage: "folder.badge.plus") {
            workspace.promptForNewFolder(in: node.url)
        }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") {
            workspace.revealInFinder(node.url)
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            CopyActions.copyFilePath(node.url)
        }
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

    final class Holder {
        weak var window: NSWindow?
        weak var workspace: WorkspaceManager?

        init(workspace: WorkspaceManager) {
            self.workspace = workspace
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
            context.coordinator.window = window
            workspace.registerWindow(window)
        }
    }
}

struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceManager) private var focusedWorkspace

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Workspace File") {
                activeWorkspace?.createNewFile()
            }
            .disabled(activeWorkspace?.rootURL == nil)

            Button("New Workspace Folder…") {
                activeWorkspace?.promptForNewFolder()
            }
            .disabled(activeWorkspace?.rootURL == nil)

            Divider()

            Button("Open…") {
                openFileOrWorkspace()
            }
            .keyboardShortcut("o", modifiers: .command)
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
