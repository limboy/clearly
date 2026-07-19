import SwiftUI
import AppKit
import ClearlyCore

/// Per-document scene root: hosts the editor / preview, find bar, jump-to-line
/// bar, outline panel, and the floating bottom toolbar (mode picker / counts /
/// copy / outline). One instance per `DocumentGroup` window.
struct ContentView: View {
    @Binding var text: String
    let fileURL: URL?
    let embedsOutline: Bool
    let minimumContentWidth: CGFloat
    let onViewModeChange: ((ViewMode) -> Void)?

    private var externalViewModeBinding: Binding<ViewMode>?
    @State private var internalViewMode: ViewMode
    @StateObject private var outlineState: OutlineState
    @StateObject private var findState = FindState()
    @StateObject private var jumpToLineState = JumpToLineState()
    @State private var hasCreatedPreview: Bool

    @AppStorage(FontPreferences.sizeKey) private var fontSize = FontPreferences.defaultSize
    @AppStorage(FontPreferences.familyKey) private var fontFamily = FontPreferences.defaultFamily.rawValue
    @AppStorage("contentWidth") private var contentWidth: String = "off"
    @AppStorage("showLineNumbers") private var showLineNumbers: Bool = false

    /// Stable per-window key for ScrollBridge / SelectionBridge. Re-keyed on
    /// document URL change so two windows on different files don't collide.
    @State private var positionSyncID: String = UUID().uuidString

    init(
        text: Binding<String>,
        fileURL: URL?,
        outlineState: OutlineState? = nil,
        embedsOutline: Bool = true,
        minimumContentWidth: CGFloat = 600,
        viewMode: Binding<ViewMode>? = nil,
        onViewModeChange: ((ViewMode) -> Void)? = nil
    ) {
        self._text = text
        self.fileURL = fileURL
        self._outlineState = StateObject(wrappedValue: outlineState ?? OutlineState())
        self.embedsOutline = embedsOutline
        self.minimumContentWidth = minimumContentWidth
        self.externalViewModeBinding = viewMode
        self.onViewModeChange = onViewModeChange
        // Never land a blank document in Preview — there'd be nothing to see
        // and no obvious way to edit.
        let raw = UserDefaults.standard.string(forKey: "defaultViewMode") ?? "edit"
        let preferred = ViewMode(rawValue: raw) ?? .edit
        // Avoid allocating a trimmed copy of the entire document just to
        // decide whether Preview would be empty. Nonblank documents normally
        // exit this scan on their first character.
        let isBlank = text.wrappedValue.allSatisfy(\.isWhitespace)
        let initialMode: ViewMode = (preferred == .preview && isBlank) ? .edit : preferred
        self._internalViewMode = State(initialValue: initialMode)
        self._hasCreatedPreview = State(initialValue: initialMode == .preview)
    }

    private var currentViewModeBinding: Binding<ViewMode> {
        externalViewModeBinding ?? $internalViewMode
    }

    private var viewMode: ViewMode {
        currentViewModeBinding.wrappedValue
    }

    private var contentWidthEm: CGFloat? {
        switch contentWidth {
        case "narrow": return 50
        case "medium": return 65
        case "wide": return 80
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if findState.isVisible {
                FindBarView(findState: findState)
                Divider()
            }
            if jumpToLineState.isVisible {
                JumpToLineBar(state: jumpToLineState)
                Divider()
            }

            HStack(spacing: 0) {
                mainPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if embedsOutline && outlineState.isVisible {
                    OutlineView(
                        outlineState: outlineState,
                        isEditorVisible: viewMode == .edit
                    )
                    .frame(width: outlineState.width)
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
        .background {
            if embedsOutline {
                DocumentToolbarObserver(viewMode: currentViewModeBinding, outlineState: outlineState)
            }
        }
        .focusedSceneValue(\.findState, findState)
        .focusedSceneValue(\.outlineState, outlineState)
        .focusedSceneValue(\.viewMode, currentViewModeBinding)
        .focusedSceneValue(\.exportPDFAction) { exportPDF() }
        .focusedSceneValue(\.printDocumentAction) { printDocument() }
        .onAppear {
            if viewMode == .preview {
                hasCreatedPreview = true
            }
            outlineState.parseHeadings(from: text)
            onViewModeChange?(viewMode)
            if let fileURL {
                NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
            }
        }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .preview {
                hasCreatedPreview = true
            }
            onViewModeChange?(newMode)
        }
        .onChange(of: text) { _, newText in
            outlineState.parseHeadings(from: newText)
        }
        .onChange(of: fileURL) { _, newURL in
            // Re-key bridges when the document is saved/renamed so a new
            // file's scroll position doesn't inherit the old fraction.
            positionSyncID = UUID().uuidString
            if let newURL {
                NSDocumentController.shared.noteNewRecentDocumentURL(newURL)
            }
        }
        .watchExternalChanges(fileURL: fileURL, text: $text) { url in
            // Sync SwiftUI's underlying NSDocument's fileModificationDate to
            // the new on-disk mtime — without this, the next autosave detects
            // a conflict and shows "could not be autosaved" dialog. We
            // deliberately do NOT try to suppress the title's "Edited"
            // decoration: SwiftUI tracks its own FileDocument-vs-disk diff
            // for that, and the indicator is a useful "doc changed under you"
            // signal anyway.
            let target = url.standardizedFileURL
            guard let doc = NSDocumentController.shared.documents.first(where: { $0.fileURL?.standardizedFileURL == target }) else { return }
            if let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                doc.fileModificationDate = mtime
            }
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        ZStack {
            EditorView(
                text: $text,
                fontSize: CGFloat(fontSize),
                fontFamily: fontFamily,
                fileURL: fileURL,
                mode: viewMode,
                positionSyncID: positionSyncID,
                findState: findState,
                outlineState: outlineState,
                extraBottomInset: 0,
                showLineNumbers: showLineNumbers,
                jumpToLineState: jumpToLineState,
                contentWidthEm: contentWidthEm
            )
            .opacity(viewMode == .edit ? 1 : 0)
            .allowsHitTesting(viewMode == .edit)

            // WKWebView startup and Markdown-to-HTML rendering are expensive.
            // Do not create either for edit-only windows; after Preview is
            // visited once, retain it so switching modes stays instant.
            if hasCreatedPreview || viewMode == .preview {
                PreviewView(
                    markdown: text,
                    fontSize: CGFloat(fontSize),
                    fontFamily: fontFamily,
                    mode: viewMode,
                    positionSyncID: positionSyncID,
                    fileURL: fileURL,
                    findState: findState,
                    outlineState: outlineState,
                    onTaskToggle: { line, checked in
                        toggleTask(line: line, checked: checked)
                    },
                    contentWidthEm: contentWidthEm
                )
                .opacity(viewMode == .preview ? 1 : 0)
                .allowsHitTesting(viewMode == .preview)
            }
        }
    }

    /// Toggle the `[ ]` / `[x]` on the source line that produced this rendered
    /// task. Called from the preview-side click handler.
    private func toggleTask(line: Int, checked: Bool) {
        let lines = text.components(separatedBy: "\n")
        guard line > 0, line <= lines.count else { return }
        let original = lines[line - 1]
        let updated: String
        if checked {
            updated = original.replacingOccurrences(of: "[ ]", with: "[x]", options: [], range: original.range(of: "[ ]"))
        } else {
            updated = original.replacingOccurrences(of: "[x]", with: "[ ]", options: .caseInsensitive, range: original.range(of: "[x]", options: .caseInsensitive))
        }
        guard updated != original else { return }
        var newLines = lines
        newLines[line - 1] = updated
        text = newLines.joined(separator: "\n")
    }

    private func exportPDF() {
        PDFExporter().exportPDF(
            markdown: text,
            fontSize: CGFloat(fontSize),
            fontFamily: fontFamily,
            fileURL: fileURL
        )
    }

    private func printDocument() {
        PDFExporter().printHTML(
            markdown: text,
            fontSize: CGFloat(fontSize),
            fontFamily: fontFamily,
            fileURL: fileURL
        )
    }
}

/// Native AppKit NSToolbar observer for single-document windows.
/// Replaces SwiftUI's .toolbar modifier to prevent BarAppearanceBridge KVO crashes.
struct DocumentToolbarObserver: NSViewRepresentable {
    @Binding var viewMode: ViewMode
    @ObservedObject var outlineState: OutlineState

    final class Holder: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
        private static let modeItemIdentifier = NSToolbarItem.Identifier("com.sabotage.clearly.document.mode")
        private static let outlineItemIdentifier = NSToolbarItem.Identifier("com.sabotage.clearly.document.outline")

        weak var window: NSWindow?
        var viewModeBinding: Binding<ViewMode>?
        var outlineState: OutlineState?

        private let toolbar = NSToolbar(identifier: NSToolbar.Identifier("document.toolbar.\(UUID().uuidString)"))

        override init() {
            super.init()
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
        }

        func installToolbar(in window: NSWindow) {
            guard window.toolbar !== toolbar else {
                toolbar.validateVisibleItems()
                return
            }
            self.window = window
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [
                .flexibleSpace,
                Self.modeItemIdentifier,
                Self.outlineItemIdentifier,
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
            if itemIdentifier == Self.modeItemIdentifier {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                updateModeItem(item)
                item.target = self
                item.action = #selector(toggleViewMode(_:))
                item.isBordered = true
                item.visibilityPriority = .high
                return item
            }

            if itemIdentifier == Self.outlineItemIdentifier {
                let item = NSToolbarItem(itemIdentifier: itemIdentifier)
                item.label = "Outline"
                item.paletteLabel = "Outline"
                item.toolTip = "Toggle Outline"
                item.image = NSImage(
                    systemSymbolName: "list.bullet.indent",
                    accessibilityDescription: "Toggle Outline"
                )
                item.target = self
                item.action = #selector(toggleOutline(_:))
                item.isBordered = true
                item.visibilityPriority = .high
                return item
            }

            return nil
        }

        func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
            if item.itemIdentifier == Self.modeItemIdentifier {
                updateModeItem(item)
                return true
            }
            return true
        }

        private func updateModeItem(_ item: NSToolbarItem) {
            let isEdit = viewModeBinding?.wrappedValue == .edit
            let title = isEdit ? "Preview" : "Edit"
            let imageName = isEdit ? "text.viewfinder" : "pencil"
            item.label = title
            item.paletteLabel = title
            item.toolTip = isEdit ? "Switch to Preview" : "Switch to Edit"
            item.image = NSImage(
                systemSymbolName: imageName,
                accessibilityDescription: title
            )
        }

        @MainActor @objc private func toggleViewMode(_ sender: NSToolbarItem) {
            guard let binding = viewModeBinding else { return }
            binding.wrappedValue = (binding.wrappedValue == .edit ? .preview : .edit)
            toolbar.validateVisibleItems()
        }

        @MainActor @objc private func toggleOutline(_ sender: NSToolbarItem) {
            outlineState?.isVisible.toggle()
        }
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.viewModeBinding = _viewMode
        context.coordinator.outlineState = outlineState
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.installToolbar(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.viewModeBinding = _viewMode
        context.coordinator.outlineState = outlineState
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.installToolbar(in: window)
        }
    }
}
