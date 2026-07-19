import AppKit
import SwiftUI
import ClearlyCore

private final class SpotlightSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the window-level search overlay. Keeping the focused search field in a
/// child window prevents it from changing the workspace's SwiftUI safe area.
@MainActor
final class SpotlightSearchController {
    private weak var parentWindow: NSWindow?
    private var panel: SpotlightSearchPanel?
    private var hostingView: NSHostingView<SpotlightSearchView>?
    private var resizeObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var focusToken = UUID()

    func register(parentWindow: NSWindow) {
        self.parentWindow = parentWindow
    }

    func unregister(parentWindow: NSWindow) {
        guard self.parentWindow === parentWindow else { return }
        dismiss(restoreParentFocus: false)
        self.parentWindow = nil
    }

    func present(
        over window: NSWindow? = nil,
        workspace: WorkspaceManager,
        recentFileURLs: [URL],
        onOpenNewWindow: ((URL) -> Void)?
    ) {
        let targetWindow = window ?? parentWindow
        guard let targetWindow else { return }

        focusToken = UUID()

        let presentationBinding = Binding(
            get: { [weak self] in self?.panel != nil },
            set: { [weak self] isPresented in
                if !isPresented {
                    self?.dismiss()
                }
            }
        )
        let searchView = SpotlightSearchView(
            workspace: workspace,
            isPresented: presentationBinding,
            recentFileURLs: recentFileURLs,
            onOpenNewWindow: onOpenNewWindow,
            focusToken: focusToken
        )

        if let panel {
            hostingView?.rootView = searchView
            panel.makeKeyAndOrderFront(nil)
            addEscapeMonitor()
            return
        }

        let panel = SpotlightSearchPanel(
            contentRect: targetWindow.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: searchView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        parentWindow = targetWindow
        self.panel = panel
        self.hostingView = hostingView
        observe(targetWindow)
        addEscapeMonitor()

        targetWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(restoreParentFocus: Bool = true) {
        removeEscapeMonitor()
        guard let panel else { return }
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        hostingView = nil
        removeObservers()

        if restoreParentFocus, parent?.isVisible == true {
            parent?.makeKey()
        }
    }

    private func addEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func observe(_ window: NSWindow) {
        let notificationCenter = NotificationCenter.default
        resizeObserver = notificationCenter.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let parentWindow, let panel else { return }
                panel.setFrame(parentWindow.frame, display: true)
            }
        }
        closeObserver = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismiss(restoreParentFocus: false)
            }
        }
    }

    private func removeObservers() {
        let notificationCenter = NotificationCenter.default
        if let resizeObserver {
            notificationCenter.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let closeObserver {
            notificationCenter.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }
}

struct SpotlightSearchView: View {
    @Bindable var workspace: WorkspaceManager
    @Binding var isPresented: Bool
    var recentFileURLs: [URL] = []
    var onOpenNewWindow: ((URL) -> Void)?
    var focusToken: UUID = UUID()

    @State private var query: String = ""
    @State private var selectedScope: WorkspaceSearchScope = .all
    @State private var results: [WorkspaceSearchResult] = []
    @State private var selectedIndex: Int = 0
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack {
            // Modal dialog
            VStack(spacing: 0) {
                searchHeaderView
                Divider()
                resultsBodyView
                Divider()
                footerView
            }
            .frame(width: 580)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.outlinePanelBackgroundSwiftUI)
                    .shadow(color: Color.black.opacity(0.35), radius: 24, x: 0, y: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .padding(.top, -100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear {
            requestFieldFocus()
            performSearch(query: query, scope: selectedScope)
        }
        .onChange(of: focusToken) { _, _ in
            requestFieldFocus()
        }
        .onChange(of: query) { _, newQuery in
            performSearch(query: newQuery, scope: selectedScope)
        }
        .onChange(of: selectedScope) { _, newScope in
            performSearch(query: query, scope: newScope)
        }
    }

    private func requestFieldFocus() {
        DispatchQueue.main.async {
            isFieldFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFieldFocused = true
        }
    }

    private var searchHeaderView: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Search workspace by title or content...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFieldFocused)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    cycleScope()
                    return .handled
                }
                .onKeyPress(.return) {
                    let flags = NSApp.currentEvent?.modifierFlags ?? []
                    openSelectedResult(inNewWindow: flags.contains(.command))
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            scopeSelectorView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var scopeSelectorView: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceSearchScope.allCases) { scope in
                Button {
                    selectedScope = scope
                } label: {
                    Text(scope.rawValue)
                        .font(.system(size: 11, weight: selectedScope == scope ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selectedScope == scope ? Color.accentColor : Color.clear)
                        )
                        .foregroundColor(selectedScope == scope ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var resultsBodyView: some View {
        Group {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedQuery.isEmpty {
                recentFilesView
            } else if results.isEmpty && !isSearching {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No results found for \"\(query)\"")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text("Try switching scopes or using different keywords")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsListView
            }
        }
        .frame(height: 320)
    }

    @ViewBuilder
    private var recentFilesView: some View {
        let filesToShow = Array(recentFilesToDisplay.prefix(7))
        if filesToShow.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("Type a keyword to search titles and contents in real time")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT FILES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filesToShow.enumerated()), id: \.element.path) { index, url in
                            RecentFileRow(
                                url: url,
                                rootURL: workspace.rootURL,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .onTapGesture {
                                selectedIndex = index
                                _ = workspace.openFile(at: url)
                                dismiss()
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var recentFilesToDisplay: [URL] {
        if !recentFileURLs.isEmpty {
            return recentFileURLs
        }
        let editable = WorkspaceSearchEngine.collectEditableFiles(from: workspace.tree)
        return editable.map(\.url)
    }

    private var resultsListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        SpotlightSearchResultRow(
                            result: result,
                            isSelected: index == selectedIndex
                        )
                        .id(index)
                        .onTapGesture {
                            selectedIndex = index
                            openSelectedResult()
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .frame(height: 320)
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            shortcutPill("Tab", label: "Scope")
            shortcutPill("↑↓", label: "Navigate")
            shortcutPill("↵", label: "Open")
            shortcutPill("⌘↵", label: "New Window")
            Spacer()
            Text("esc to close")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    private func shortcutPill(_ key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(3)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func cycleScope() {
        let allScopes = WorkspaceSearchScope.allCases
        guard let currentIndex = allScopes.firstIndex(of: selectedScope) else { return }
        let nextIndex = (currentIndex + 1) % allScopes.count
        selectedScope = allScopes[nextIndex]
    }

    private func performSearch(query: String, scope: WorkspaceSearchScope) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            selectedIndex = 0
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }

            let searchResults = await WorkspaceSearchEngine.search(
                query: trimmed,
                scope: scope,
                in: workspace.tree,
                rootURL: workspace.rootURL
            )

            if !Task.isCancelled {
                self.results = searchResults
                self.selectedIndex = 0
                self.isSearching = false
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let currentCount = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? recentFilesToDisplay.count : results.count
        guard currentCount > 0 else { return }
        let newIndex = selectedIndex + delta
        if newIndex >= 0 && newIndex < currentCount {
            selectedIndex = newIndex
        }
    }

    private func openSelectedResult(inNewWindow: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let recents = recentFilesToDisplay
            guard selectedIndex >= 0 && selectedIndex < recents.count else { return }
            let url = recents[selectedIndex]
            if inNewWindow {
                onOpenNewWindow?(url)
            } else {
                _ = workspace.openFile(at: url)
            }
            dismiss()
            return
        }

        guard selectedIndex >= 0 && selectedIndex < results.count else { return }
        let result = results[selectedIndex]

        if inNewWindow {
            onOpenNewWindow?(result.url)
        } else {
            _ = workspace.openFile(at: result.url)
            if case .content(let line, _) = result.matchKind {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(
                        name: .jumpToLineInEditor,
                        object: nil,
                        userInfo: ["line": line]
                    )
                }
            }
        }
        dismiss()
    }

    private func dismiss() {
        searchTask?.cancel()
        isPresented = false
    }
}

private struct SpotlightSearchResultRow: View {
    let result: WorkspaceSearchResult
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(result.relativePath)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }

                if case .content(let line, let snippet) = result.matchKind {
                    HStack(spacing: 4) {
                        Text("L\(line)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.08))
                            .cornerRadius(3)
                            .foregroundColor(isSelected ? .white : .secondary)

                        Text(snippet)
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            if isSelected {
                Text("↵ Open")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch result.matchKind {
        case .title:
            return "doc.text"
        case .content:
            return "text.quote"
        }
    }
}

private struct RecentFileRow: View {
    let url: URL
    let rootURL: URL?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 14))
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var relativePath: String {
        let fullPath = url.standardizedFileURL.path
        let rootPath = rootURL?.standardizedFileURL.path ?? ""
        if !rootPath.isEmpty && fullPath.hasPrefix(rootPath) {
            var rel = String(fullPath.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }
}
