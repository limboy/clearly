import XCTest
@testable import ClearlyCore

final class FontPreferencesTests: XCTestCase {
    func testMigrationPreservesLegacyPreviewSizeRelationship() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(19.0, forKey: FontPreferences.editorSizeKey)

        FontPreferences.migrateLegacySettings(in: defaults)

        #if os(iOS)
        XCTAssertEqual(defaults.double(forKey: FontPreferences.previewSizeKey), 21)
        #else
        XCTAssertEqual(defaults.double(forKey: FontPreferences.previewSizeKey), 23)
        #endif
    }

    func testMigrationDoesNotOverwriteIndependentPreviewSize() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(14.0, forKey: FontPreferences.editorSizeKey)
        defaults.set(27.0, forKey: FontPreferences.previewSizeKey)

        FontPreferences.migrateLegacySettings(in: defaults)

        XCTAssertEqual(defaults.double(forKey: FontPreferences.previewSizeKey), 27)
    }

    func testMigrationInstallsTypographyDefaultsForFreshUser() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FontPreferences.migrateLegacySettings(in: defaults)

        XCTAssertEqual(
            defaults.string(forKey: FontPreferences.editorFamilyKey),
            ContentFontFamily.sfMono.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: FontPreferences.previewFamilyKey),
            ContentFontFamily.sanFrancisco.rawValue
        )
        XCTAssertEqual(
            defaults.double(forKey: FontPreferences.previewSizeKey),
            FontPreferences.defaultPreviewSize
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "FontPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
