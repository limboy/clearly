import XCTest
@testable import ClearlyCore

final class FontPreferencesTests: XCTestCase {
    func testMigrationUsesEditorValuesFromSeparatedSettings() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(19.0, forKey: "editorFontSize")
        defaults.set(ContentFontFamily.newYork.rawValue, forKey: "editorFontFamily")
        defaults.set(27.0, forKey: "previewFontSize")
        defaults.set(ContentFontFamily.sanFrancisco.rawValue, forKey: "previewFontFamily")

        FontPreferences.migrateLegacySettings(in: defaults)

        XCTAssertEqual(defaults.double(forKey: FontPreferences.sizeKey), 19)
        XCTAssertEqual(
            defaults.string(forKey: FontPreferences.familyKey),
            ContentFontFamily.newYork.rawValue
        )
    }

    func testMigrationUsesOriginalPreviewFamilyAsFallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(14.0, forKey: "editorFontSize")
        defaults.set(ContentFontFamily.newYork.rawValue, forKey: "previewFontFamily")

        FontPreferences.migrateLegacySettings(in: defaults)

        XCTAssertEqual(defaults.double(forKey: FontPreferences.sizeKey), 14)
        XCTAssertEqual(
            defaults.string(forKey: FontPreferences.familyKey),
            ContentFontFamily.newYork.rawValue
        )
    }

    func testMigrationDoesNotOverwriteSharedSettings() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(22.0, forKey: FontPreferences.sizeKey)
        defaults.set(ContentFontFamily.sanFrancisco.rawValue, forKey: FontPreferences.familyKey)
        defaults.set(13.0, forKey: "editorFontSize")
        defaults.set(ContentFontFamily.newYork.rawValue, forKey: "editorFontFamily")

        FontPreferences.migrateLegacySettings(in: defaults)

        XCTAssertEqual(defaults.double(forKey: FontPreferences.sizeKey), 22)
        XCTAssertEqual(
            defaults.string(forKey: FontPreferences.familyKey),
            ContentFontFamily.sanFrancisco.rawValue
        )
    }

    func testMigrationInstallsSharedDefaultsForFreshUser() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FontPreferences.migrateLegacySettings(in: defaults)

        XCTAssertEqual(
            defaults.double(forKey: FontPreferences.sizeKey),
            FontPreferences.defaultSize
        )
        XCTAssertEqual(
            defaults.string(forKey: FontPreferences.familyKey),
            FontPreferences.defaultFamily.rawValue
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "FontPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
