import Foundation
import SwiftUI
import AppKit

public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformPasteboard = NSPasteboard
public typealias PlatformTextView = NSTextView
public typealias PlatformTextStorage = NSTextStorage
public typealias PlatformParagraphStyle = NSMutableParagraphStyle

public enum PlatformFontWeight {
    case regular
    case bold
}

public enum PlatformFontDesign {
    case sansSerif
    case serif
    case monospaced
}

public enum PlatformDevice {
    /// User-visible device name, used in conflict sibling filenames.
    public static func currentName() -> String {
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

public enum PlatformTextAttributes {
    public static let font = NSAttributedString.Key.font
    public static let foregroundColor = NSAttributedString.Key.foregroundColor
    public static let backgroundColor = NSAttributedString.Key.backgroundColor
    public static let paragraphStyle = NSAttributedString.Key.paragraphStyle
    public static let baselineOffset = NSAttributedString.Key.baselineOffset
    public static let strikethroughStyle = NSAttributedString.Key.strikethroughStyle
    public static let singleUnderlineStyleValue = NSUnderlineStyle.single.rawValue
}

public extension PlatformFont {
    static func clearlySystemFont(
        ofSize size: CGFloat,
        weight: PlatformFontWeight,
        design: PlatformFontDesign
    ) -> PlatformFont {
        let platformWeight: NSFont.Weight = weight == .bold ? .bold : .regular
        if design == .monospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: platformWeight)
        }
        let base = NSFont.systemFont(ofSize: size, weight: platformWeight)
        guard design == .serif,
              let descriptor = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
    }

    static func clearlyMonospacedSystemFont(ofSize size: CGFloat, weight: PlatformFontWeight) -> PlatformFont {
        clearlySystemFont(ofSize: size, weight: weight, design: .monospaced)
    }

    /// Returns a font with italic trait applied. Falls back to `self` if unavailable.
    func withItalicTrait() -> PlatformFont {
        return NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }

    /// Builds a bold + italic monospaced system font at the given size.
    static func clearlyMonospacedBoldItalic(size: CGFloat) -> PlatformFont {
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        return NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
    }
}

public extension PlatformColor {
    static func clearlyColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> PlatformColor {
        return NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// Loads a named color from the `ClearlyCore` asset catalog (`Bundle.module`).
    /// The asset must exist — unresolved names trap.
    static func clearlyAsset(named name: String) -> PlatformColor {
        guard let color = NSColor(named: NSColor.Name(name), bundle: .module) else {
            fatalError("Missing color asset '\(name)' in ClearlyCore Colors.xcassets")
        }
        return color
    }

    enum Appearance: Sendable {
        case light
        case dark
    }

    /// Resolves this color's sRGB components for the given appearance and returns a CSS
    /// color string: `#RRGGBB` when alpha rounds to 1, `rgba(r, g, b, a)` otherwise.
    func cssHexString(for appearance: Appearance) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        let target = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) ?? NSAppearance(named: .aqua)!
        var resolved: NSColor?
        target.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.sRGB)
        }
        if let resolved {
            r = resolved.redComponent
            g = resolved.greenComponent
            b = resolved.blueComponent
            a = resolved.alphaComponent
        }
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        if a >= 0.9995 {
            return String(format: "#%02X%02X%02X", ri, gi, bi)
        }
        let alpha = (a * 1000).rounded() / 1000
        let alphaStr: String
        if alpha == alpha.rounded() {
            alphaStr = String(Int(alpha))
        } else {
            alphaStr = String(format: "%g", alpha)
        }
        return "rgba(\(ri), \(gi), \(bi), \(alphaStr))"
    }
}

public extension Color {
    init(platformColor: PlatformColor) {
        self.init(nsColor: platformColor)
    }
}
