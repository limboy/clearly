import AppKit
import SwiftUI
import ClearlyCore

enum WorkspaceScene {
    static let id = "workspace"
}

/// Unique macOS workspace window: a persistent folder tree on the left and
/// Clearly's existing editor/preview surface on the right.
struct WorkspaceView: View {
    @State private var workspace = WorkspaceManager.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var outlineState = OutlineState()
    @State private var currentViewMode: ViewMode = .edit

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
                .frame(width: 240)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(WorkspaceWindowObserver())
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

    var body: some View {
        ContentUnavailableView {
            Label(
                workspace.rootURL == nil ? "Open a Workspace" : "No Markdown Files",
                systemImage: workspace.rootURL == nil ? "folder.badge.plus" : "doc.text"
            )
        } description: {
            Text(
                workspace.rootURL == nil
                    ? "Choose a folder to browse and edit its Markdown files."
                    : "Create a Markdown file in this folder to get started."
            )
        } actions: {
            if workspace.rootURL == nil {
                Button("Open Folder…") {
                    workspace.chooseWorkspace()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("New File") {
                    workspace.createNewFile()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Captures the SwiftUI-owned workspace window without taking over its delegate.
struct WorkspaceWindowObserver: NSViewRepresentable {
    final class Holder {
        weak var window: NSWindow?
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(from: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        register(from: nsView, context: context)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Holder) {
        guard let window = coordinator.window else { return }
        WorkspaceManager.shared.unregisterWindow(window)
    }

    private func register(from view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.window = window
            window.setFrameAutosaveName("ClearlyWorkspaceWindow")
            WorkspaceManager.shared.registerWindow(window)
        }
    }
}

struct OpenWorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Workspace File") {
                WorkspaceManager.shared.createNewFile()
            }
            .disabled(WorkspaceManager.shared.rootURL == nil)

            Button("New Workspace Folder…") {
                WorkspaceManager.shared.promptForNewFolder()
            }
            .disabled(WorkspaceManager.shared.rootURL == nil)

            Divider()

            Button("Open Workspace") {
                ClearlyAppDelegate.shared?.ensureRegularAndActivate()
                openWindow(id: WorkspaceScene.id)
            }
            .disabled(WorkspaceManager.shared.rootURL == nil)

            Button("Open Folder as Workspace…") {
                let workspace = WorkspaceManager.shared
                if workspace.chooseWorkspace() {
                    ClearlyAppDelegate.shared?.ensureRegularAndActivate()
                    openWindow(id: WorkspaceScene.id)
                }
            }
        }
    }
}
