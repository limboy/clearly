import AppKit
import SwiftUI
import ClearlyCore

struct OutlineView: View {
    static var width: CGFloat { OutlineState.defaultWidth }

    @ObservedObject var outlineState: OutlineState
    var isEditorVisible: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("OUTLINE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(1.5)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? Theme.separatorOpacityDark : Theme.separatorOpacity))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.outlinePanelBackgroundSwiftUI)
            .zIndex(1)

            if outlineState.headings.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("No headings")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("Add headings with # to build an outline")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(outlineState.headings) { heading in
                            HeadingRow(heading: heading) {
                                if isEditorVisible {
                                    outlineState.scrollToRange?(heading.range)
                                }
                                outlineState.scrollToHeading?(heading)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.outlinePanelBackgroundSwiftUI)
        .background(OutlineTitlebarReservation(width: outlineState.width))
        .overlay(alignment: .leading) {
            OutlineResizeHandle(outlineState: outlineState)
        }
        .frame(width: outlineState.width)
    }
}

private struct OutlineResizeHandle: View {
    @ObservedObject var outlineState: OutlineState
    @State private var dragStartWidth: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? Theme.separatorOpacityDark : Theme.separatorOpacity))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .overlay(ResizeCursorView())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartWidth == nil {
                                    dragStartWidth = outlineState.width
                                }
                                if let startWidth = dragStartWidth {
                                    let newWidth = startWidth - value.translation.width
                                    outlineState.width = max(OutlineState.minWidth, min(OutlineState.maxWidth, newWidth))
                                }
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            outlineState.width = OutlineState.defaultWidth
                        }
                    }
            }
    }
}

private struct ResizeCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizeCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.discardCursorRects()
        nsView.addCursorRect(nsView.bounds, cursor: .resizeLeftRight)
    }
}

private final class ResizeCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

/// Keeps the native document title out of the outline's fixed-width column.
///
/// SwiftUI lays a `DocumentGroup` title (and a `NavigationSplitView` title)
/// across the whole window even when a sibling view owns the trailing edge.
/// A transparent trailing titlebar accessory makes that ownership visible to
/// AppKit's title layout while preserving the native title, document icon,
/// edited indicator, and titlebar dragging behavior.
private struct OutlineTitlebarReservation: NSViewRepresentable {
    let width: CGFloat

    final class Coordinator {
        let accessoryViewController: NSTitlebarAccessoryViewController
        weak var window: NSWindow?
        var isActive = true

        init() {
            let controller = NSTitlebarAccessoryViewController()
            controller.layoutAttribute = .right
            controller.view = PassthroughTitlebarView()
            accessoryViewController = controller
        }

        func attach(to window: NSWindow, width: CGFloat) {
            guard isActive else { return }

            if self.window !== window {
                detach()
                self.window = window
            }

            accessoryViewController.view.setFrameSize(
                NSSize(width: width, height: 1)
            )

            if !window.titlebarAccessoryViewControllers.contains(where: {
                $0 === accessoryViewController
            }) {
                window.addTitlebarAccessoryViewController(accessoryViewController)
            }
        }

        func detach() {
            guard let window,
                  let index = window.titlebarAccessoryViewControllers.firstIndex(where: {
                      $0 === accessoryViewController
                  }) else {
                self.window = nil
                return
            }
            window.removeTitlebarAccessoryViewController(at: index)
            self.window = nil
        }

        func deactivate() {
            isActive = false
            detach()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        attach(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attach(from: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.deactivate()
    }

    private func attach(from view: NSView, coordinator: Coordinator) {
        if let window = view.window {
            coordinator.attach(to: window, width: width)
        } else {
            DispatchQueue.main.async { [weak view] in
                guard let window = view?.window else { return }
                coordinator.attach(to: window, width: width)
            }
        }
    }
}

private final class PassthroughTitlebarView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct HeadingRow: View {
    let heading: HeadingItem
    let onTap: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var font: Font {
        switch heading.level {
        case 1: return .system(size: 13, weight: .semibold)
        case 2: return .system(size: 12, weight: .medium)
        default: return .system(size: 12, weight: .regular)
        }
    }

    private var indent: CGFloat {
        CGFloat(heading.level - 1) * 14
    }

    var body: some View {
        Button(action: onTap) {
            Text(heading.title)
                .font(font)
                .foregroundStyle(heading.level <= 2 ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12 + indent)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered
                    ? Color.primary.opacity(colorScheme == .dark ? Theme.hoverOpacityDark - 0.03 : 0.05)
                    : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { hovering in
            withAnimation(Theme.Motion.hover) {
                isHovered = hovering
            }
        }
    }
}
