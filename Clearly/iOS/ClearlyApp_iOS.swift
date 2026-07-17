import SwiftUI
import ClearlyCore

@main
struct ClearlyApp_iOS: App {
    init() {
        FontPreferences.migrateLegacySettings()
    }

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentDetailBody(document: file.$document, fileURL: file.fileURL)
        }
    }
}
