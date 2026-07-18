import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KeyboardShortcuts
import ClearlyCore
#if canImport(Sparkle)
import Sparkle
#endif

// MARK: - App Delegate

@MainActor
final class ClearlyAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) weak var shared: ClearlyAppDelegate?

    var openWorkspaceWindowClosure: ((URL) -> Void)?

    private weak var trackedSettingsWindow: NSWindow?
    private var isOpeningSettingsFromMenuBar = false
    private var observers: [Any] = []
    private var localEventMonitors: [Any] = []

    /// Set when a termination request must actually exit, either from the
    /// menubar "Quit Clearly" item or Sparkle's install-and-relaunch flow.
    /// Other terminate paths (⌘Q, File ▸ Quit) are treated as "drop to
    /// menubar" when the menubar-only toggle is on.
    private var allowFullQuit = false

    /// True while a launcher / open panel is in flight that hasn't yet
    /// produced a document. Defers `applicationShouldTerminate(After…)` so
    /// the brief zero-window window between "panel closes" and "doc window
    /// appears" doesn't quit the app when `keepRunningMenubarOnly` is false.
    /// Set whenever a doc-yielding panel is shown; cleared in
    /// `updateActivationPolicy` once a real `NSDocument` exists.
    private var isDocumentPanelPresented = false

    /// SwiftUI side stores this with `@AppStorage("keepRunningMenubarOnly")`,
    /// default `true`. Use `object(forKey:)` to distinguish unset (→ true)
    /// from an explicit `false` the user wrote.
    private var keepRunningMenubarOnly: Bool {
        (UserDefaults.standard.object(forKey: "keepRunningMenubarOnly") as? Bool) ?? true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Avoid Dock-icon flash when the user launches with the toggle on.
        // The `didBecomeMain` observer flips us back to `.regular` once a
        // document window appears (Finder-open, untitled-on-launch, etc.).
        if keepRunningMenubarOnly {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        injectFontSubmenu()

        DiagnosticLog.log("didFinishLaunching: keepRunning=\(keepRunningMenubarOnly), docs=\(NSDocumentController.shared.documents.count)")

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            let window = notification.object as? NSWindow
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let window { self.clearTrackedSettingsWindow(window) }
            }
            // willClose fires while the window is still in NSApp.windows;
            // defer the policy check until after it's removed.
            DispatchQueue.main.async {
                Task { @MainActor [weak self] in
                    self?.updateActivationPolicy()
                }
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                if let window = notification.object as? NSWindow {
                    WorkspaceManager.windowDidBecomeMain(window)
                }
                self?.updateActivationPolicy()
            }
        })

        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { event in
                let shortcutModifiers = event.modifierFlags.intersection([
                    .command, .shift, .option, .control,
                ])
                guard !event.isARepeat,
                      event.charactersIgnoringModifiers == "\u{7f}",
                      shortcutModifiers == .command,
                      let workspace = WorkspaceManager.mainWindowManager,
                      let targetURL = workspace.selectedTreeURL
                        ?? workspace.currentFileURL else {
                    return event
                }
                workspace.moveToTrash(targetURL)
                return nil
            }
        ) {
            localEventMonitors.append(monitor)
        }
    }

    func applicationWillUpdate(_ notification: Notification) {
        // SwiftUI may rebuild the main menu after launch. Reinstall this
        // idempotent AppKit addition before AppKit updates menu state.
        injectSpellingMenu()
        consolidateOpenCommands()
        injectOpenRecentMenu()
        configureWorkspaceTrashCommand()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DiagnosticLog.log("appShouldTerminateAfterLast: keepRunning=\(keepRunningMenubarOnly), panel=\(isDocumentPanelPresented), docs=\(NSDocumentController.shared.documents.count)")
        if isSettingsWindowOpeningOrVisible {
            DiagnosticLog.log("appShouldTerminateAfterLast: Settings active, keeping app alive")
            return false
        }
        if keepRunningMenubarOnly {
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return false
    }

    /// If a launcher / open panel is currently in flight, defer a quit by
    /// re-checking 3 seconds later. Returns false (no defer) when there's
    /// no panel pending.
    @discardableResult
    private func scheduleDeferredQuitIfPanelInFlight() -> Bool {
        guard isDocumentPanelPresented else { return false }
        DiagnosticLog.log("scheduleDeferredQuit: deferring 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            // Clear first so any re-entry into a terminate path doesn't
            // re-arm another defer.
            self.isDocumentPanelPresented = false
            let docCount = NSDocumentController.shared.documents.count
            DiagnosticLog.log("scheduleDeferredQuit: fired, docs=\(docCount)")
            if docCount == 0 && !self.isSettingsWindowOpeningOrVisible {
                NSApp.terminate(nil)
            } else if self.isSettingsWindowOpeningOrVisible {
                DiagnosticLog.log("scheduleDeferredQuit: canceled, Settings active")
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DiagnosticLog.log("appShouldTerminate: allowFullQuit=\(allowFullQuit), keepRunning=\(keepRunningMenubarOnly), panel=\(isDocumentPanelPresented), docs=\(NSDocumentController.shared.documents.count)")
        // Workspace windows are not owned by NSDocumentController, so flush
        // their active buffer explicitly before either quitting or dropping
        // back to menu-bar-only mode.
        guard WorkspaceManager.prepareAllForTermination() else {
            return .terminateCancel
        }
        if allowFullQuit { return .terminateNow }
        guard keepRunningMenubarOnly else {
            // menubar-off: a launcher / open panel may have dismissed and
            // SwiftUI may be in the middle of creating the chosen document.
            // Defer the actual quit until either it shows up or 3s lapses.
            if scheduleDeferredQuitIfPanelInFlight() { return .terminateCancel }
            return .terminateNow
        }

        WorkspaceManager.closeAllWindowsForMenuBar()

        // Drop to menubar instead of terminating. `closeAllDocuments` walks
        // every NSDocument (including SwiftUI DocumentGroup ones), prompting
        // for unsaved changes — looping NSApp.windows and calling performClose
        // does NOT reliably close DocumentGroup windows.
        let docs = NSDocumentController.shared.documents
        if docs.isEmpty {
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        }
        // Launcher-dismiss fires both terminate methods. By this point
        // NSDocumentController has added the user-picked doc to `.documents`,
        // but its SwiftUI scene is still constructing. Falling through to
        // `closeAllDocuments` would tear that brand-new doc down mid-build
        // and crash the app (#377). Bail without touching it; the natural
        // `didBecomeMain` → `updateActivationPolicy` flow clears the flag
        // once the doc registers, so the next Cmd+Q hits the normal path.
        if isDocumentPanelPresented {
            DiagnosticLog.log("appShouldTerminate: panel-in-flight with new doc, cancel without closing")
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        }
        NSDocumentController.shared.closeAllDocuments(
            withDelegate: self,
            didCloseAllSelector: #selector(menubarOnlyDidCloseAllDocuments(_:didCloseAll:contextInfo:)),
            contextInfo: nil
        )
        return .terminateLater
    }

    @objc private func menubarOnlyDidCloseAllDocuments(_ controller: NSDocumentController, didCloseAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // Always reply NO — we're dropping to menubar regardless of whether
        // all docs closed (user may have cancelled a save).
        NSApp.reply(toApplicationShouldTerminate: false)
        if didCloseAll {
            // All docs closed. Hide Dock immediately; don't go through
            // `updateActivationPolicy()` because the just-closed windows are
            // still in `NSApp.windows` for a beat and would read as "doc open".
            NSApp.setActivationPolicy(.accessory)
        } else {
            // User cancelled at least one save — at least one doc window
            // remains; recompute against the real state.
            updateActivationPolicy()
        }
    }

    func requestFullQuitFromMenuBar() {
        allowFullQuit = true
        defer { allowFullQuit = false }
        NSApp.terminate(nil)
    }

    fileprivate func prepareForUpdaterRelaunch() {
        DiagnosticLog.log("updaterWillRelaunch: allowing full quit")
        allowFullQuit = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for monitor in localEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        localEventMonitors.removeAll()
    }

    /// Drives the Dock icon. Called from window observers and from the
    /// Settings toggle's `.onChange`. Always `.regular` when the toggle is
    /// off. When the toggle is on, `.regular` only while a document window
    /// is on screen.
    func updateActivationPolicy() {
        // Clear the panel-flow flag once a real `NSDocument` exists. The
        // SwiftUI launcher also counts as a "doc window" by frame/class but
        // doesn't have an associated `NSDocument`, so we use the controller's
        // documents collection (which the launcher is absent from) as the
        // authoritative "is a real doc up" signal.
        if !NSDocumentController.shared.documents.isEmpty || WorkspaceManager.hasAnyVisibleWindow {
            isDocumentPanelPresented = false
        }
        guard keepRunningMenubarOnly else {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            return
        }
        if hasDocumentWindows() {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        } else {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Surfaces the Dock icon and brings the app forward. Used by the
    /// menubar dropdown before opening a window — `updateActivationPolicy()`
    /// will then keep us `.regular` until the window closes.
    func ensureRegularAndActivate() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hasDocumentWindows() -> Bool {
        NSApp.windows.contains(where: isDocumentWindow)
    }

    private func isDocumentWindow(_ window: NSWindow) -> Bool {
        // `isVisible` filters out windows that have just closed but are still
        // in `NSApp.windows` waiting to be released — those would otherwise
        // pin the activation policy to `.regular` for a beat after Cmd+Q.
        guard window.isVisible, !(window is NSPanel), !window.isSheet, window.level != .floating else { return false }
        return window.frame.width >= 200 && window.frame.height >= 200 && window !== trackedSettingsWindow
    }

    // MARK: - Settings window tracking (menu-bar Settings… coordination)

    private var isSettingsWindowOpeningOrVisible: Bool {
        isOpeningSettingsFromMenuBar || trackedSettingsWindow?.isVisible == true
    }

    func prepareForMenuBarSettingsActivation() {
        isOpeningSettingsFromMenuBar = true
    }

    func registerSettingsWindow(_ window: NSWindow) {
        trackedSettingsWindow = window
        isOpeningSettingsFromMenuBar = false
    }

    func clearTrackedSettingsWindow(_ window: NSWindow) {
        if trackedSettingsWindow === window {
            trackedSettingsWindow = nil
        }
        isOpeningSettingsFromMenuBar = false
    }

    // MARK: - AppKit menu injection

    /// Spelling / grammar submenu under Edit. SwiftUI's default Edit menu
    /// doesn't include this — but `NSTextView` selectors expect it.
    private func injectSpellingMenu() {
        guard let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu else { return }
        guard let findIndex = editMenu.items.firstIndex(where: {
            $0.title.hasPrefix("Find")
                || ($0.keyEquivalent == "f" && $0.keyEquivalentModifierMask.contains(.command))
        }) else { return }
        guard !editMenu.items.contains(where: { $0.title == "Spelling and Grammar" }) else { return }

        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingImage = NSImage(
            systemSymbolName: "textformat.abc.dottedunderline",
            accessibilityDescription: "Spelling and Grammar"
        )?.withSymbolConfiguration(.init(textStyle: .body, scale: .medium))
        spellingImage?.isTemplate = true
        spellingItem.image = spellingImage
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        let showItem = NSMenuItem(title: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        showItem.keyEquivalentModifierMask = [.command]
        spellingMenu.addItem(showItem)
        let checkItem = NSMenuItem(title: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        checkItem.keyEquivalentModifierMask = [.command]
        spellingMenu.addItem(checkItem)
        spellingMenu.addItem(.separator())
        spellingMenu.addItem(NSMenuItem(title: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: ""))
        spellingMenu.addItem(NSMenuItem(title: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: ""))
        spellingMenu.addItem(NSMenuItem(title: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: ""))
        spellingItem.submenu = spellingMenu

        editMenu.insertItem(spellingItem, at: findIndex + 1)
    }

    /// Shared editor/preview font submenu under View.
    private func injectFontSubmenu() {
        guard let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu else { return }
        guard !viewMenu.items.contains(where: { $0.title == "Font" }) else { return }

        let fontSubmenu = NSMenu(title: "Font")
        for (title, value) in [("San Francisco", "sanFrancisco"), ("New York", "newYork"), ("SF Mono", "sfMono")] {
            let item = NSMenuItem(title: title, action: #selector(setFontAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            fontSubmenu.addItem(item)
        }
        let fontMenuItem = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fontMenuItem.submenu = fontSubmenu
        viewMenu.addItem(.separator())
        viewMenu.addItem(fontMenuItem)
    }

    /// `DocumentGroup` contributes its own Open command. Clearly inserts a
    /// unified Open command that accepts either a document or a workspace
    /// folder. Transfer the system command's icon to the unified command,
    /// then remove the duplicate.
    private func consolidateOpenCommands() {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        let openItems = fileMenu.items.filter { item in
            item.submenu == nil
                && item.title.replacingOccurrences(of: "…", with: "...") == "Open..."
        }
        guard openItems.count > 1 else { return }

        let unifiedItem = openItems.first(where: { item in
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            return item.keyEquivalent.lowercased() == "o" && modifiers == .command
        }) ?? openItems[0]

        for duplicate in openItems where duplicate !== unifiedItem {
            if unifiedItem.image == nil, let image = duplicate.image {
                unifiedItem.image = image
            }
            fileMenu.removeItem(duplicate)
        }
    }

    /// Injects an "Open Recent" submenu under File if not already present.
    private func injectOpenRecentMenu() {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        guard !fileMenu.items.contains(where: {
            $0.title == "Open Recent" || $0.submenu?.title == "Open Recent"
        }) else { return }

        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let clockImage = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "Open Recent"
        )?.withSymbolConfiguration(.init(textStyle: .body, scale: .medium))
        clockImage?.isTemplate = true
        openRecentItem.image = clockImage

        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        openRecentItem.submenu = recentMenu

        if let openIndex = fileMenu.items.firstIndex(where: {
            $0.title.replacingOccurrences(of: "…", with: "...").hasPrefix("Open...")
        }) {
            fileMenu.insertItem(openRecentItem, at: openIndex + 1)
        } else if let newIndex = fileMenu.items.firstIndex(where: { $0.title.hasPrefix("New") }) {
            fileMenu.insertItem(openRecentItem, at: newIndex + 1)
        } else {
            fileMenu.insertItem(openRecentItem, at: 0)
        }
    }

    /// SwiftUI context-menu shortcuts aren't installed in the app's main
    /// command chain. Give the File-menu command a real AppKit key equivalent
    /// so ⌘Delete wins over NSTextView's delete-to-line-start handling.
    private func configureWorkspaceTrashCommand() {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
              let item = fileMenu.items.first(where: { $0.title == "Move To Trash" }) else {
            return
        }
        item.target = self
        item.action = #selector(moveWorkspaceFileToTrash(_:))
        item.keyEquivalent = "\u{8}"
        item.keyEquivalentModifierMask = [.command]
    }

    @objc private func setFontAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: FontPreferences.familyKey)
    }

    @objc private func moveWorkspaceFileToTrash(_ sender: NSMenuItem) {
        guard let workspace = WorkspaceManager.mainWindowManager,
              let targetURL = workspace.selectedTreeURL
                ?? workspace.currentFileURL else {
            return
        }
        workspace.moveToTrash(targetURL)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setFontAction(_:)) {
            let current = FontPreferences.fontFamily().rawValue
            menuItem.state = (menuItem.representedObject as? String) == current ? .on : .off
            return true
        }
        if menuItem.action == #selector(moveWorkspaceFileToTrash(_:)) {
            guard let workspace = WorkspaceManager.mainWindowManager else {
                return false
            }
            return workspace.selectedTreeURL != nil
                || workspace.currentFileURL != nil
        }
        return true
    }

    // MARK: - NSMenuDelegate (Open Recent)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()

        let recentURLs = NSDocumentController.shared.recentDocumentURLs
        if recentURLs.isEmpty {
            let emptyItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentDocuments(_:)), keyEquivalent: "")
            emptyItem.target = self
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for url in recentURLs {
            let title = url.lastPathComponent
            let item = NSMenuItem(title: title, action: #selector(openRecentDocumentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url

            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon

            menu.addItem(item)
        }

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentDocuments(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    @objc private func openRecentDocumentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURL(url)
    }

    @objc private func clearRecentDocuments(_ sender: NSMenuItem) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    func openURL(_ url: URL) {
        ensureRegularAndActivate()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory {
            if let activeWorkspace = WorkspaceManager.active, activeWorkspace.rootURL == nil {
                activeWorkspace.attachWorkspace(at: url)
            } else if let closure = openWorkspaceWindowClosure {
                closure(url)
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    NSAlert(error: error).runModal()
                }
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openURL(url)
        }
    }
}

#if canImport(Sparkle)
@MainActor
private final class ClearlyUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        ClearlyAppDelegate.shared?.prepareForUpdaterRelaunch()
    }
}
#endif

// MARK: - App Entry

@main
struct ClearlyApp: App {
    @NSApplicationDelegateAdaptor(ClearlyAppDelegate.self) var appDelegate
    @AppStorage("themePreference") private var themePreference = "system"
    @State private var scratchpadManager = ScratchpadManager.shared
    @State private var scratchpadStore = ScratchpadStore.shared

    #if canImport(Sparkle)
    private let updaterDelegate: ClearlyUpdaterDelegate
    private let updaterController: SPUStandardUpdaterController
    #endif

    init() {
        FontPreferences.migrateLegacySettings()
        DiagnosticLog.trimIfNeeded()
        DiagnosticLog.log("App launched")
        #if canImport(Sparkle)
        let updaterDelegate = ClearlyUpdaterDelegate()
        self.updaterDelegate = updaterDelegate
        #if DEBUG
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        #else
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        #endif
        #endif
    }

    private var resolvedColorScheme: ColorScheme? {
        switch themePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(text: file.$document.text, fileURL: file.fileURL)
                .preferredColorScheme(resolvedColorScheme)
        }
        .defaultSize(width: 800, height: 900)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                #if canImport(Sparkle)
                CheckForUpdatesView(updater: updaterController.updater)
                #endif
            }
            WorkspaceCommands()
            EditorCommands()
            CommandGroup(replacing: .help) {
                Button("Sample Document") {
                    openSampleDocument()
                }
                Divider()
                Button("Export Diagnostic Log…") {
                    do {
                        let logText = try DiagnosticLog.exportRecentLogs()
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.plainText]
                        panel.nameFieldStringValue = "Clearly-Diagnostic-Log.txt"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        try logText.write(to: url, atomically: true, encoding: .utf8)
                    } catch {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }

        WindowGroup(
            "Workspace",
            id: WorkspaceScene.id,
            for: WorkspaceScene.Value.self
        ) { value in
            WorkspaceView(folderURL: value.wrappedValue.folderURL)
                .preferredColorScheme(resolvedColorScheme)
        } defaultValue: {
            WorkspaceScene.Value(folderURL: nil)
        }
        .defaultSize(width: 1120, height: 780)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        Settings {
            #if canImport(Sparkle)
            SettingsView(updater: updaterController.updater)
                .preferredColorScheme(resolvedColorScheme)
            #else
            SettingsView()
                .preferredColorScheme(resolvedColorScheme)
            #endif
        }

        MenuBarExtra("Scratchpads", image: "ScratchpadMenuBarIcon") {
            ScratchpadMenuBar(manager: scratchpadManager, store: scratchpadStore)
        }
    }

    /// Copies the bundled sample doc into a temp file and opens it as a new
    /// document. The temp copy avoids overwriting the bundle resource.
    private func openSampleDocument() {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "md") else { return }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sample Document.md")
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.copyItem(at: url, to: tempURL)
        NSDocumentController.shared.openDocument(withContentsOf: tempURL, display: true) { _, _, _ in }
    }
}

// MARK: - Settings window registration

struct SettingsWindowObserver: NSViewRepresentable {
    final class Holder {
        weak var window: NSWindow?
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        registerWindow(from: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        registerWindow(from: nsView, context: context)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Holder) {
        guard let window = coordinator.window else { return }
        ClearlyAppDelegate.shared?.clearTrackedSettingsWindow(window)
    }

    private func registerWindow(from view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.window = window
            ClearlyAppDelegate.shared?.registerSettingsWindow(window)
        }
    }
}

// MARK: - Focused-value keys (per-document menu binding)

private struct FindStateKey: FocusedValueKey {
    typealias Value = FindState
}

private struct OutlineStateKey: FocusedValueKey {
    typealias Value = OutlineState
}

private struct ViewModeKey: FocusedValueKey {
    typealias Value = Binding<ViewMode>
}

private struct ExportPDFActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct PrintDocumentActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var findState: FindState? {
        get { self[FindStateKey.self] }
        set { self[FindStateKey.self] = newValue }
    }
    var outlineState: OutlineState? {
        get { self[OutlineStateKey.self] }
        set { self[OutlineStateKey.self] = newValue }
    }
    var viewMode: Binding<ViewMode>? {
        get { self[ViewModeKey.self] }
        set { self[ViewModeKey.self] = newValue }
    }
    var exportPDFAction: (() -> Void)? {
        get { self[ExportPDFActionKey.self] }
        set { self[ExportPDFActionKey.self] = newValue }
    }
    var printDocumentAction: (() -> Void)? {
        get { self[PrintDocumentActionKey.self] }
        set { self[PrintDocumentActionKey.self] = newValue }
    }
}

// MARK: - Per-document command views

struct EditorCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            ExportPrintCommands()
        }
        CommandGroup(after: .textEditing) {
            FindCommand()
        }
        CommandGroup(after: .toolbar) {
            ViewModeCommands()
            OutlineToggleCommand()
            LineNumbersToggleCommand()
        }
        CommandGroup(replacing: .textFormatting) {
            FontSizeCommands()
            Divider()
            Button("Bold") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleBold(_:))) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleItalic(_:))) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Strikethrough") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleStrikethrough(_:))) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Heading") { performFormattingCommand(selector: #selector(ClearlyTextView.insertHeading(_:))) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Link…") { performFormattingCommand(selector: #selector(ClearlyTextView.insertLink(_:))) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Image…") { performFormattingCommand(selector: #selector(ClearlyTextView.insertImage(_:))) }
            Divider()
            Button("Bullet List") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleBulletList(_:))) }
            Button("Numbered List") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleNumberedList(_:))) }
            Button("Todo") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleTodoList(_:))) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Quote") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleBlockquote(_:))) }
            Button("Horizontal Rule") { performFormattingCommand(selector: #selector(ClearlyTextView.insertHorizontalRule(_:))) }
            Button("Table") { performFormattingCommand(selector: #selector(ClearlyTextView.insertMarkdownTable(_:))) }
            Divider()
            Button("Code") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleInlineCode(_:))) }
            Button("Code Block") { performFormattingCommand(selector: #selector(ClearlyTextView.insertCodeBlock(_:))) }
            Divider()
            Button("Math") { performFormattingCommand(selector: #selector(ClearlyTextView.toggleInlineMath(_:))) }
            Button("Math Block") { performFormattingCommand(selector: #selector(ClearlyTextView.insertMathBlock(_:))) }
            Divider()
            Button("Page Break") { performFormattingCommand(selector: #selector(ClearlyTextView.insertPageBreak(_:))) }
        }
    }
}

struct ExportPrintCommands: View {
    @FocusedValue(\.exportPDFAction) var exportPDFAction
    @FocusedValue(\.printDocumentAction) var printDocumentAction

    var body: some View {
        Button("Export as PDF…") {
            exportPDFAction?()
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(exportPDFAction == nil)

        Button("Print…") {
            printDocumentAction?()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(printDocumentAction == nil)
    }
}

struct FindCommand: View {
    @FocusedValue(\.findState) var findState

    var body: some View {
        Button {
            findState?.toggle()
        } label: {
            Label("Find…", systemImage: "text.page.badge.magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(findState == nil)
    }
}

struct OutlineToggleCommand: View {
    @FocusedValue(\.outlineState) var outlineState

    var body: some View {
        Button {
            outlineState?.isVisible.toggle()
        } label: {
            Label("Toggle Outline", systemImage: "list.bullet.indent")
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(outlineState == nil)
    }
}


struct LineNumbersToggleCommand: View {
    @AppStorage("showLineNumbers") private var showLineNumbers = false

    var body: some View {
        Button {
            showLineNumbers.toggle()
        } label: {
            Label(
                showLineNumbers ? "Hide Line Numbers" : "Show Line Numbers",
                systemImage: "number"
            )
        }
    }
}

struct ViewModeCommands: View {
    @FocusedValue(\.viewMode) var mode

    var body: some View {
        Button {
            mode?.wrappedValue = .edit
        } label: {
            Label("Editor", systemImage: "square.and.pencil")
        }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(mode == nil)

        Button {
            mode?.wrappedValue = .preview
        } label: {
            Label("Preview", systemImage: "eye")
        }
        .keyboardShortcut("2", modifiers: .command)
        .disabled(mode == nil)
    }
}

struct FontSizeCommands: View {
    @AppStorage(FontPreferences.sizeKey) private var fontSize = FontPreferences.defaultSize

    var body: some View {
        Button("Increase Font Size") {
            fontSize = min(fontSize + 1, 28)
        }
        .keyboardShortcut("+", modifiers: .command)

        Button("Decrease Font Size") {
            fontSize = max(fontSize - 1, 12)
        }
        .keyboardShortcut("-", modifiers: .command)
    }
}

@MainActor
func performFormattingCommand(selector: Selector) {
    NSApp.sendAction(selector, to: nil, from: nil)
}

// MARK: - Sparkle Check for Updates menu item

#if canImport(Sparkle)
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var observation: Any?

    init(updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }
}
#endif
