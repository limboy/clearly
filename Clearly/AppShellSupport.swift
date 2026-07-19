import AppKit
import ClearlyCore

/// Notification channels paired between `EditorView` and `PreviewView`
/// for cross-pane jumps (click a heading / find-result in one pane and
/// scroll the other to the same line).
extension Notification.Name {
    static let scrollPreviewToLine = Notification.Name("ClearlyScrollPreviewToLine")
    static let flushEditorBuffer = Notification.Name("ClearlyFlushEditorBuffer")
    static let highlightTextInEditor = Notification.Name("ClearlyHighlightTextInEditor")
    static let highlightTextInPreview = Notification.Name("ClearlyHighlightTextInPreview")
    static let jumpToLineInEditor = Notification.Name("ClearlyJumpToLineInEditor")
}

/// Holds a weak reference to the currently focused `ClearlyTextView`.
/// Menu commands (formatting, etc.) target whichever editor most
/// recently became key. This works for both DocumentGroup windows and the
/// workspace's single active editor without coupling commands to either
/// window model.
@MainActor
final class ActiveEditor {
    static let shared = ActiveEditor()
    weak var textView: ClearlyTextView?
    private init() {}
}
