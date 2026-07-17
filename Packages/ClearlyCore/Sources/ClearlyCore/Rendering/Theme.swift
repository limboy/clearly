import Foundation
import SwiftUI

public enum ContentFontFamily: String, CaseIterable, Sendable {
    case sanFrancisco
    case newYork
    case sfMono

    public var displayName: String {
        switch self {
        case .sanFrancisco: return "San Francisco"
        case .newYork: return "New York"
        case .sfMono: return "SF Mono"
        }
    }

    fileprivate var platformDesign: PlatformFontDesign {
        switch self {
        case .sanFrancisco: return .sansSerif
        case .newYork: return .serif
        case .sfMono: return .monospaced
        }
    }

    fileprivate var swiftUIDesign: Font.Design {
        switch self {
        case .sanFrancisco: return .default
        case .newYork: return .serif
        case .sfMono: return .monospaced
        }
    }
}

public enum FontPreferences {
    public static let sizeKey = "contentFontSize"
    public static let familyKey = "contentFontFamily"
    public static let defaultFamily = ContentFontFamily.sfMono

    public static let defaultSize: Double = 12

    /// Consolidates older editor/preview preferences into one content font.
    /// Editor values win when the independent settings exist; the original
    /// preview-family key remains a fallback for pre-split installs.
    public static func migrateLegacySettings(in defaults: UserDefaults = .standard) {
        if defaults.object(forKey: sizeKey) == nil {
            let legacySize = defaults.double(forKey: "editorFontSize")
            defaults.set(legacySize > 0 ? legacySize : defaultSize, forKey: sizeKey)
        }

        if defaults.object(forKey: familyKey) == nil {
            let legacyFamily = [
                defaults.string(forKey: "editorFontFamily"),
                defaults.string(forKey: "previewFontFamily")
            ]
            .compactMap { $0 }
            .compactMap(ContentFontFamily.init(rawValue:))
            .first ?? defaultFamily
            defaults.set(legacyFamily.rawValue, forKey: familyKey)
        }
    }

    public static func fontSize(in defaults: UserDefaults = .standard) -> CGFloat {
        let size = defaults.double(forKey: sizeKey)
        return size > 0 ? CGFloat(size) : CGFloat(defaultSize)
    }

    public static func fontFamily(in defaults: UserDefaults = .standard) -> ContentFontFamily {
        guard let rawValue = defaults.string(forKey: familyKey) else {
            return defaultFamily
        }
        return ContentFontFamily(rawValue: rawValue) ?? defaultFamily
    }
}

public enum Theme {
    // MARK: - Editor Font
    public static var editorFontSize: CGFloat {
        FontPreferences.fontSize()
    }

    public static var editorFontFamily: ContentFontFamily {
        FontPreferences.fontFamily()
    }

    public static var editorFont: PlatformFont {
        makeEditorFont(size: editorFontSize)
    }

    public static var editorHeadingFont: PlatformFont {
        makeEditorFont(size: editorFontSize + 4, weight: .bold)
    }

    public static var editorBoldFont: PlatformFont {
        makeEditorFont(size: editorFontSize, weight: .bold)
    }

    public static var editorBoldItalicFont: PlatformFont {
        makeEditorFont(size: editorFontSize, weight: .bold).withItalicTrait()
    }

    public static var editorFontSwiftUI: Font {
        Font.system(size: editorFontSize, design: editorFontFamily.swiftUIDesign)
    }

    private static func makeEditorFont(
        size: CGFloat,
        weight: PlatformFontWeight = .regular
    ) -> PlatformFont {
        PlatformFont.clearlySystemFont(
            ofSize: size,
            weight: weight,
            design: editorFontFamily.platformDesign
        )
    }

    // MARK: - Margins
    public static let editorInsetX: CGFloat = 60
    public static let editorInsetTop: CGFloat = 10
    public static let editorInsetBottom: CGFloat = 40

    // MARK: - Line Spacing
    public static let lineSpacing: CGFloat = 8

    /// Desired line height = font natural height + lineSpacing
    public static var editorLineHeight: CGFloat {
        let font = editorFont
        return ceil(font.ascender - font.descender + font.leading) + lineSpacing
    }

    /// Baseline offset to vertically center text within the line height
    public static var editorBaselineOffset: CGFloat {
        let font = editorFont
        let naturalHeight = ceil(font.ascender - font.descender + font.leading)
        return (editorLineHeight - naturalHeight) / 2
    }

    // MARK: - Dynamic Colors (auto-resolve for light/dark via Bundle.module asset catalog)

    public static let backgroundColor = PlatformColor.clearlyAsset(named: "Background")
    public static let textColor = PlatformColor.clearlyAsset(named: "Text")
    public static let syntaxColor = PlatformColor.clearlyAsset(named: "Syntax")
    public static let headingColor = PlatformColor.clearlyAsset(named: "Heading")
    public static let boldColor = PlatformColor.clearlyAsset(named: "Bold")
    public static let italicColor = PlatformColor.clearlyAsset(named: "Italic")
    public static let codeColor = PlatformColor.clearlyAsset(named: "Code")
    public static let linkColor = PlatformColor.clearlyAsset(named: "Link")
    public static let mathColor = PlatformColor.clearlyAsset(named: "Math")
    public static let blockquoteColor = PlatformColor.clearlyAsset(named: "Blockquote")
    public static let frontmatterColor = PlatformColor.clearlyAsset(named: "Frontmatter")
    public static let highlightColor = PlatformColor.clearlyAsset(named: "Highlight")
    public static let highlightBackgroundColor = PlatformColor.clearlyAsset(named: "HighlightBackground")
    public static let footnoteColor = PlatformColor.clearlyAsset(named: "Footnote")
    public static let htmlTagColor = PlatformColor.clearlyAsset(named: "HtmlTag")
    public static let findHighlightColor = PlatformColor.clearlyAsset(named: "FindHighlight")
    public static let findCurrentHighlightColor = PlatformColor.clearlyAsset(named: "FindCurrentHighlight")
    public static let errorColor = PlatformColor.clearlyAsset(named: "Error")
    public static let warningColor = PlatformColor.clearlyAsset(named: "Warning")

    // MARK: - SwiftUI Color Wrappers

    public static var backgroundColorSwiftUI: Color { Color(platformColor: backgroundColor) }
    public static var textColorSwiftUI: Color { Color(platformColor: textColor) }
    public static var syntaxColorSwiftUI: Color { Color(platformColor: syntaxColor) }
    public static var headingColorSwiftUI: Color { Color(platformColor: headingColor) }
    public static var boldColorSwiftUI: Color { Color(platformColor: boldColor) }
    public static var italicColorSwiftUI: Color { Color(platformColor: italicColor) }
    public static var codeColorSwiftUI: Color { Color(platformColor: codeColor) }
    public static var linkColorSwiftUI: Color { Color(platformColor: linkColor) }
    public static var mathColorSwiftUI: Color { Color(platformColor: mathColor) }
    public static var blockquoteColorSwiftUI: Color { Color(platformColor: blockquoteColor) }
    public static var frontmatterColorSwiftUI: Color { Color(platformColor: frontmatterColor) }
    public static var highlightColorSwiftUI: Color { Color(platformColor: highlightColor) }
    public static var highlightBackgroundColorSwiftUI: Color { Color(platformColor: highlightBackgroundColor) }
    public static var footnoteColorSwiftUI: Color { Color(platformColor: footnoteColor) }
    public static var htmlTagColorSwiftUI: Color { Color(platformColor: htmlTagColor) }
    public static var findHighlightColorSwiftUI: Color { Color(platformColor: findHighlightColor) }
    public static var findCurrentHighlightColorSwiftUI: Color { Color(platformColor: findCurrentHighlightColor) }
    public static var errorColorSwiftUI: Color { Color(platformColor: errorColor) }
    public static var warningColorSwiftUI: Color { Color(platformColor: warningColor) }

    // MARK: - Accent Color

    public static let accentColor = PlatformColor.clearlyAsset(named: "Accent")

    public static var accentColorSwiftUI: Color { Color(platformColor: accentColor) }

    // MARK: - Panel Backgrounds

    public static let sidebarBackground = PlatformColor.clearlyAsset(named: "SidebarBackground")

    public static var sidebarBackgroundSwiftUI: Color { Color(platformColor: sidebarBackground) }

    public static let outlinePanelBackground = PlatformColor.clearlyAsset(named: "OutlinePanelBackground")

    public static var outlinePanelBackgroundSwiftUI: Color { Color(platformColor: outlinePanelBackground) }

    // MARK: - Separators

    public static let separatorOpacity: Double = 0.06
    public static let separatorOpacityDark: Double = 0.10
    public static let structuralSeparatorOpacity: Double = 0.10
    public static let structuralSeparatorOpacityDark: Double = 0.15

    // MARK: - Hover & Selection

    public static let hoverOpacity: Double = 0.06
    public static let hoverOpacityDark: Double = 0.08
    public static let selectionOpacity: Double = 0.15
    public static let selectionOpacityDark: Double = 0.22

    /// Color-scheme-aware separator line color (`Color.primary` modulated by the scheme's opacity).
    public static func separatorColor(inDark isDark: Bool) -> Color {
        Color.primary.opacity(isDark ? separatorOpacityDark : separatorOpacity)
    }

    /// Color-scheme-aware hover background (`Color.primary` modulated by the scheme's opacity).
    public static func hoverColor(inDark isDark: Bool) -> Color {
        Color.primary.opacity(isDark ? hoverOpacityDark : hoverOpacity)
    }

    /// Color-scheme-aware multi-document tab bar background. Mirrors the Mac
    /// `TabBarView`'s `tabBackground` derivation — light: subtle primary tint,
    /// dark: translucent sidebar background.
    public static func tabBarBackgroundColor(inDark isDark: Bool) -> Color {
        isDark ? sidebarBackgroundSwiftUI.opacity(0.6) : Color.primary.opacity(0.04)
    }

    // MARK: - Folder Colors

    public static let folderColorPalette: [(name: String, color: PlatformColor)] = [
        ("red",    PlatformColor.clearlyColor(red: 0.90, green: 0.30, blue: 0.28, alpha: 1)),
        ("orange", PlatformColor.clearlyColor(red: 0.92, green: 0.55, blue: 0.22, alpha: 1)),
        ("yellow", PlatformColor.clearlyColor(red: 0.88, green: 0.75, blue: 0.20, alpha: 1)),
        ("green",  PlatformColor.clearlyColor(red: 0.35, green: 0.75, blue: 0.40, alpha: 1)),
        ("teal",   PlatformColor.clearlyColor(red: 0.25, green: 0.70, blue: 0.70, alpha: 1)),
        ("blue",   PlatformColor.clearlyColor(red: 0.30, green: 0.55, blue: 0.90, alpha: 1)),
        ("purple", PlatformColor.clearlyColor(red: 0.60, green: 0.40, blue: 0.85, alpha: 1)),
        ("pink",   PlatformColor.clearlyColor(red: 0.85, green: 0.40, blue: 0.60, alpha: 1)),
    ]

    public static func folderColor(named name: String) -> PlatformColor? {
        folderColorPalette.first { $0.name == name }?.color
    }

    // MARK: - Typography (chrome)

    /// Font tokens for chrome surfaces (sidebar rows, tab bar, toolbar, sheets, find overlay).
    /// Editor canvas typography lives on `editorFont` / `editorFontSwiftUI` above.
    /// Dynamic Type wrapping for chrome fonts happens at call sites in Phase 12b.8.
    public enum Typography {
        /// Tab bar labels (active + inactive share the same font; use font weight on the view to differentiate if needed).
        public static let tabLabel = Font.system(size: 12, weight: .medium)
        /// Active tab label (same size + weight as inactive; pinned for call-site clarity).
        public static let tabLabelActive = Font.system(size: 12, weight: .medium)
        /// Sidebar / file list row text.
        public static let sidebarRow = Font.system(size: 13)
        /// Small-caps-style section headers ("OUTLINE", "BACKLINKS"). Apply `.tracking(sectionHeaderTracking)` at the call site.
        public static let sectionHeader = Font.system(size: 11, weight: .semibold)
        /// Letter-spacing for `sectionHeader`; applied via `.tracking(_:)` modifier on the `Text`.
        public static let sectionHeaderTracking: CGFloat = 1.5
        /// Count pill badges (Backlinks "12", Tags "3", etc.).
        public static let countBadge = Font.system(size: 10, weight: .medium)
        /// Toolbar button / menu item labels.
        public static let toolbarLabel = Font.system(size: 14, weight: .medium)
        /// Search / find field text.
        public static let findField = Font.system(size: 13)
        /// Find-result count ("3 of 7"), prev/next arrow button text.
        public static let findCount = Font.system(size: 11, weight: .medium)
        /// Welcome screen title ("Welcome to Clearly"). Apply `.tracking(-0.3)` at the call site to match Mac.
        public static let welcomeTitle = Font.system(size: 26, weight: .semibold)
        /// Welcome screen subtitle copy.
        public static let welcomeSubtitle = Font.system(size: 14)
    }

    // MARK: - Spacing

    /// Layout metrics shared by the app's chrome.
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16

        /// Source-list row height.
        public static let sidebarRowHeight: CGFloat = 28
        /// Multi-document tab bar total height.
        public static let tabBarHeight: CGFloat = 38
        /// Bottom toolbar height.
        public static let bottomToolbarHeight: CGFloat = 40

        public static let cornerRadiusSmall: CGFloat = 6
        public static let cornerRadiusMedium: CGFloat = 8
        public static let cornerRadiusLarge: CGFloat = 12
    }

    // MARK: - Motion Presets

    public enum Motion {
        /// Quick feedback: button hovers, toggle states
        public static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.85)
        /// Primary transitions: segmented control slide, panel show/hide
        public static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.75)
        /// Ambient: empty state pulse, section expand
        public static let gentle = Animation.spring(response: 0.50, dampingFraction: 0.80)
        /// Hover backgrounds — instant-feeling
        public static let hover = Animation.easeOut(duration: 0.15)
    }
}
