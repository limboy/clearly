import SwiftUI
import ClearlyCore

struct ScratchpadShellView: View {
    @Environment(ScratchpadManager.self) private var manager
    @Environment(ScratchpadStore.self) private var store
    @Environment(ScratchpadDeleteUndoController.self) private var undo

    @State private var text: String = ""
    @State private var loadedNoteID: ScratchpadNote.ID?
    @AppStorage(FontPreferences.sizeKey) private var fontSize = FontPreferences.defaultSize
    @AppStorage(FontPreferences.familyKey) private var fontFamily = FontPreferences.defaultFamily.rawValue

    var body: some View {
        @Bindable var bindableManager = manager
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 28)
                ScratchpadEditorView(
                    text: $text,
                    fontSize: CGFloat(fontSize),
                    fontFamily: fontFamily,
                    onSave: { manager.saveCurrentAsDocument() },
                    onTextChange: { newText in
                        guard let note = manager.currentNote else { return }
                        store.write(text: newText, to: note.url)
                    }
                )
            }

            ScratchpadTitlebarBar()
                .frame(height: 28)
                .frame(maxWidth: .infinity)

            VStack {
                Spacer()
                ScratchpadDeleteUndoToast()
                    .animation(.easeOut(duration: 0.18), value: undo.pendingToken)
            }

            VStack(spacing: 0) {
                Button("") { manager.createAndShowNew() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("") { bindableManager.historyPopoverShown.toggle() }
                    .keyboardShortcut("p", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear(perform: syncText)
        .onChange(of: manager.currentNoteID) { _, _ in syncText() }
    }

    private func syncText() {
        guard let note = manager.currentNote else {
            text = ""
            loadedNoteID = nil
            return
        }
        if loadedNoteID == note.id { return }
        loadedNoteID = note.id
        text = store.loadText(for: note)
    }
}

// MARK: - Toolbar buttons

struct ScratchpadTitleMenuButton: View {
    @Environment(ScratchpadManager.self) private var manager
    @Environment(ScratchpadStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        @Bindable var bindable = manager
        Button {
            bindable.historyPopoverShown.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isHovered
                    ? Theme.hoverColor(inDark: colorScheme == .dark)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) {
                isHovered = hovering
            }
        }
        .help("Browse scratchpads (⌘P)")
        .popover(isPresented: $bindable.historyPopoverShown, arrowEdge: .bottom) {
            ScratchpadHistoryPicker {
                bindable.historyPopoverShown = false
            }
            .environment(manager)
            .environment(store)
        }
    }

    private var displayTitle: String {
        manager.currentNote?.title ?? "Scratchpad"
    }
}

struct ScratchpadPinButton: View {
    @Environment(ScratchpadManager.self) private var manager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button {
            manager.togglePinned()
        } label: {
            Image(systemName: manager.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(manager.isPinned ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 22, alignment: .center)
                .background(
                    isHovered
                        ? Theme.hoverColor(inDark: colorScheme == .dark)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) {
                isHovered = hovering
            }
        }
        .help(manager.isPinned ? "Unpin Window" : "Pin Window")
    }
}

struct ScratchpadNewNoteButton: View {
    @Environment(ScratchpadManager.self) private var manager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button {
            manager.createAndShowNew()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 22, alignment: .center)
                .background(
                    isHovered
                        ? Theme.hoverColor(inDark: colorScheme == .dark)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) {
                isHovered = hovering
            }
        }
        .help("New Scratchpad (⌘N)")
    }
}

// MARK: - Custom titlebar overlay

struct ScratchpadTitlebarBar: View {
    var body: some View {
        ZStack {
            ScratchpadTitleMenuButton()
                .padding(.horizontal, 72)

            HStack(spacing: 2) {
                Spacer(minLength: 0)
                ScratchpadPinButton()
                ScratchpadNewNoteButton()
            }
            .padding(.trailing, 10)
        }
    }
}
