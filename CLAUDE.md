# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commit message rule (hard requirement)

The `/release` skill builds the changelog by filtering commits on a scope prefix, so every commit MUST start with one:

- `[mac]` — user-visible product changes. Paths: `Clearly/`, `ClearlyQuickLook/`, `Packages/ClearlyCore/`, `Shared/Resources/`, `project.yml`, release scripts, `website/`.
- `[chore]` — dev tooling, docs, CI, meta. Excluded from the user-facing changelog. Paths: `CLAUDE.md`, `.github/`, `docs/`, `.claude/`, test harnesses, non-release scripts.

The release skill halts if it sees an un-scoped commit in the release range.

## Versioning

The `Clearly` app and `ClearlyQuickLook` ship together. Releases use tags
`v<VERSION>` (for example, `v2.3.0`) and `CHANGELOG.md`.

## What This Is

Clearly is a native Mac markdown editor built with AppKit and SwiftUI. SwiftUI's `DocumentGroup` owns the scene, one window per `.md` file. Each document has two view modes: a syntax-highlighted `NSTextView` editor and a read-only `WKWebView` preview. The app also ships a QuickLook extension (`ClearlyQuickLook`) for previewing markdown files in Finder.

There is intentionally **no** vault index, sync, AI, MCP server, sidebar, wiki-links, tags, backlinks, or command palette. If you're tempted to add infrastructure for any of those, push back — keeping this app boring is the point.

## Build & Run

The Xcode project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate        # Regenerate .xcodeproj from project.yml
xcodebuild -scheme Clearly -configuration Debug build   # Build Mac
```

Open in Xcode: `open Clearly.xcodeproj` (gitignored, so regenerate with xcodegen first).

**Worktree-local DerivedData (Conductor / parallel workspaces).** When working in a Conductor worktree, always pass `-derivedDataPath ./.build/DerivedData` to `xcodebuild`. Without it, `xcodebuild` writes to the shared `~/Library/Developer/Xcode/DerivedData` and silently picks up products from a different worktree, and `open` then launches a stale or wrong-source app. The `/verify` skill enforces this; do the same for any direct `xcodebuild` invocation.

- Deployment target: macOS 15.0
- Swift 5.9 app / Swift 5 language mode for ClearlyCore (tools 6.0 to declare `.macOS(.v15)`).
- Dependencies: `cmark-gfm` (GFM markdown → HTML), `Sparkle` (auto-updates, direct distribution only), `KeyboardShortcuts`, all via SwiftPM.

## Architecture

**Two targets** in `project.yml`:

1. **Clearly** — `DocumentGroup`-based SwiftUI app. AppKit `NSTextView` editor + `WKWebView` preview, both bridged via `NSViewRepresentable`. Includes a small `MenuBarExtra` for floating scratchpad windows.
2. **ClearlyQuickLook** — Mac app extension using `QLPreviewProvider` to render `.md` files in Finder via the same `MarkdownRenderer` used by the live preview.

**`ClearlyCore`** — local macOS Swift package at `Packages/ClearlyCore/`. Holds reusable code shared by the app and QuickLook extension. Package.swift uses swift-tools-version 6.0 so it can declare `.v15`, but pins target language mode to `.v5` to avoid Swift 6 strict concurrency complaints on the existing shared state.

Folders inside `Sources/ClearlyCore/`:

- `Rendering/` — `MarkdownRenderer` (cmark + post-processing), `MarkdownSyntaxHighlighter`, `PreviewCSS`, `MermaidSupport`, `MathSupport`, `TableSupport`, `SyntaxHighlightSupport`, `EmojiShortcodes`, `LocalImageSupport`, `FrontmatterSupport`, `Theme`.
- `State/` — `OpenDocument`, `OutlineState`, `FindState`, `JumpToLineState`, `PositionSync`, `FoldStateStore`, `ReplaceEngine`, `StatusBarState`, `TextMatcher`, `NavigationGuard`.
- `Diagnostics/` — `DiagnosticLog`, `BugReportURL`, `MemoryUsage`.
- `Editor/` — `ImageDownloader`, `ImagePasteService` (paste/drop image to disk).
- `Stats/` — `MarkdownStats` (word counts).
- `Platform/` — `PlatformFont`/`PlatformColor`/`PlatformImage`/`PlatformPasteboard` typealiases.

**Rules for `ClearlyCore`:**
- Any type or member used across the package boundary must be `public`. Consuming files need `import ClearlyCore`.
- Keep AppKit type aliases and framework adapters centralized in `Platform.swift`; app UI code stays in `Clearly/`.
- Pipeline contract for `MarkdownRenderer`: wraps `cmark_gfm_markdown_to_html()` for GFM rendering. Post-processing pipeline (in order): math (`$...$` → KaTeX spans), highlight marks (`==text==` → `<mark>`), superscript/subscript, emoji shortcodes, callouts/admonitions, TOC generation, table captions, code filename headers. Inline-syntax post-processors must use `protectCodeRegions()`/`restoreProtectedSegments()` to avoid transforming content inside `<pre>`/`<code>` tags.
- Preview JS/CSS helpers (`MathSupport`, `MermaidSupport`, `TableSupport`, `SyntaxHighlightSupport`) each expose a static `scriptHTML(for:)` that returns an empty string when the feature isn't needed for the current content.

**Shared web assets** (katex, mermaid, highlight, fonts, `demo.md`, `getting-started.md`) live at `Shared/Resources/` and are loaded via `Bundle.main.url(forResource:)`. `project.yml` bundles them into Clearly + ClearlyQuickLook via explicit `buildPhase: resources` entries. Don't move them under the package's own `resources:` unless you also migrate every `Bundle.main` lookup to `Bundle.module`.

**App code** in `Clearly/`:
- `ClearlyApp.swift` — App entry point (`@main`), `DocumentGroup`, AppKit menu injection (Spelling, Export PDF, Print, Preview Font), Sparkle bootstrap, MenuBarExtra for scratchpads. Defines focused-value keys for menu commands targeting the active document's per-window state.
- `ContentView.swift` — Per-document scene root. Hosts the mode picker, find bar, jump-to-line bar, outline panel, status bar. Owns `OutlineState`/`FindState`/`JumpToLineState`/`StatusBarState` per document and exposes them to menu commands via `.focusedSceneValue`.
- `MarkdownDocument.swift` — `FileDocument` for reading/writing `.md` files. Bound to the app's `DocumentGroup`.
- `EditorView.swift` / `ClearlyTextView.swift` — `NSViewRepresentable` wrapping the AppKit editor.
- `PreviewView.swift` — `NSViewRepresentable` wrapping the read-only `WKWebView` preview.
- `Scratchpad*.swift` — Independent menu-bar feature: floating scratchpad windows separate from `DocumentGroup`. `ScratchpadManager.saveAsDocument` reaches into `NSDocumentController.shared.openDocument(withContentsOf:)` to hand a saved scratchpad off as a regular document.
- `AppShellSupport.swift` — Notification names paired between editor and preview, plus the `ActiveEditor` registry that menu formatting commands use to find the focused `ClearlyTextView`.

### Important code-level invariants

**`NSApp.delegate` is NOT `ClearlyAppDelegate`** on Mac. SwiftUI's `@NSApplicationDelegateAdaptor` wraps the real delegate in a `SwiftUI.AppDelegate` proxy. `NSApp.delegate as? ClearlyAppDelegate` always returns nil. Use `ClearlyAppDelegate.shared` (a static weak reference set in `applicationDidFinishLaunching`) to reach the delegate from outside.

**Don't add subviews to `_NSHostingView` with Auto Layout constraints.** SwiftUI's hosting view manages subview layout internally and will override your frames/constraints, causing the subview to fill the entire hosting view. The same applies to `NSSplitView`, which treats added subviews as panes. If you need an AppKit overlay on top of SwiftUI content, subclass the underlying AppKit view instead (e.g., `DraggableWKWebView` in `PreviewView.swift` overrides `mouseDown` to enable window dragging in the top region).

**NSViewRepresentable binding gotcha.** SwiftUI can call `updateNSView` at any time — layout passes, state changes, etc. — not just in response to binding changes. When the user types, the text view's content changes immediately but the `@Binding` update is async. If `updateNSView` fires in between, it sees a mismatch and overwrites the text view with the stale binding value, causing the cursor to jump. The fix is `pendingBindingUpdates` — a counter incremented synchronously in `textDidChange` and decremented in the async block. `updateNSView` skips text replacement while this counter is > 0.

**`@Published` emits in `willSet`.** A `.sink` on `state.$prop` runs *before* the assignment completes on the same thread. Reading `state.prop` synchronously inside the sink returns the OLD value. Two safe patterns: (1) capture the new value from the closure parameter and pass it through; or (2) `DispatchQueue.main.async` inside the sink so the property is written by the time the work runs.

**SwiftUI `.keyboardShortcut(letter, modifiers: [.command, .option])` does not dispatch on this macOS** even though the menu item displays the shortcut. `.command` alone and `[.command, .shift]` work fine; the option modifier on a letter silently fails. For ⌥⌘-letter shortcuts, build an `NSMenuItem` with `keyEquivalent: "x"` + `keyEquivalentModifierMask = [.command, .option]` and inject it via the `applicationWillUpdate` AppKit-menu pattern in `ClearlyAppDelegate`.

## QuickLook + LaunchServices (macOS 15/26 gotchas)

The `.md` QuickLook preview, Finder column-view preview, and "default app for `.md`" all share LaunchServices routing and break in non-obvious ways. A working configuration requires THREE Info.plist invariants together — any one missing silently degrades to raw-text preview or wrong default opener.

**1. Use `UTExportedTypeDeclarations`, not `UTImportedTypeDeclarations`,** for `net.daringfireball.markdown` in `Clearly/Info.plist`. Imported declarations are flagged `inactive imported untrusted` by LaunchServices when no app on the system *exports* the type authoritatively, and `quicklookd` falls through to the legacy `Text.qlgenerator` (raw markdown). `UTExportedTypeDeclarations` claims authoritative ownership.

**2. `LSHandlerRank` must be `Owner`** in the same Info.plists. With `Default`, other `Owner`-rank claimants (Cursor, iA Writer, etc.) win the default-opener race even when their UTI claim is weaker.

**3. `ClearlyQuickLook/Info.plist` `QLSupportedContentTypes` must include both `net.daringfireball.markdown` AND `net.ia.markdown`.** macOS Spotlight stickily types `.md` files using whichever markdown UTI was authoritative when the file was first indexed. Users who've ever had iA Writer (or any app exporting `net.ia.markdown`) installed end up with about half their `.md` files typed as `net.ia.markdown` — even after that app is uninstalled. The QL extension only gets invoked for UTIs in `QLSupportedContentTypes`, so missing `net.ia.markdown` means raw-text preview for those files.

**Verification gotchas:**

- **`qlmanage` CLI is broken on macOS 26 for `.appex` previews.** It crashes inside `EXConcreteExtension makeExtensionContextAndXPCConnectionForRequest` with "key cannot be nil." Don't trust it for verification. The actual `quicklookd` daemon (used by Finder spacebar / column-view) handles XPC correctly. Spacebar in Finder is the only reliable test.
- **`qlmanage -m plugins` only lists legacy `.qlgenerator` bundles, not `.appex` extensions.** Empty results for markdown there are *normal*, not diagnostic.
- **`quicklookd` on macOS 26 won't invoke an `.appex` whose parent app isn't notarized+stapled.** `scripts/release.sh --dry-run` skips notarization, so its output cannot fully verify QL behavior. To test locally without cutting a real release: `release.sh --dry-run <ver>` → `cp -R build/export/Clearly.app /Applications/Clearly.app` → `ditto -c -k --keepParent /Applications/Clearly.app /tmp/x.zip` → `xcrun notarytool submit /tmp/x.zip --keychain-profile AC_PASSWORD --wait` → `xcrun stapler staple /Applications/Clearly.app` → `qlmanage -r && qlmanage -r cache` → spacebar in Finder.
- **Conductor parallel worktrees pollute LaunchServices** with hundreds of stale `Clearly Dev.app` registrations from old DerivedData paths. `lsregister -kill` was removed in macOS 15+; the working recipe is `lsregister -u <path>` per stale path. Stale entries don't affect end users (they don't have worktrees), but they make local verification a minefield because the wrong bundle can win the UTI binding.
- **Default-opener override on a polluted Mac:** Right-click `.md` → Get Info → Open with → Clearly → "Change All…". Programmatic equivalent: `LSSetDefaultRoleHandlerForContentType("net.daringfireball.markdown" as CFString, .all, "com.sabotage.clearly" as CFString)` (note: has propagation delay; `touch` + `mdimport` to refresh the file's `kMDItemContentType` cache may be needed before `urlForApplication(toOpen:)` reflects the change).

## Dual Distribution: Sparkle + App Store (Mac)

The Mac app ships through two channels from the same codebase:

1. **Direct (Sparkle)** — `scripts/release.sh` → DMG + notarize + GitHub Release + Sparkle appcast.
2. **App Store** — `scripts/release-appstore.sh` → archive without Sparkle + upload to App Store Connect.

**Conditional compilation:** All Sparkle code is wrapped in `#if canImport(Sparkle)`. The App Store build uses a modified `project.yml` (generated at build time by the release script) that removes the Sparkle package, so `canImport(Sparkle)` is false and update-related code compiles out.

**Two entitlements files:**
- `Clearly.entitlements` — direct distribution. Includes `temporary-exception` entries for Sparkle's mach-lookup XPC services and home-relative-path read access for local-image preview.
- `Clearly-AppStore.entitlements` — App Store. No temporary exceptions (App Store hard-rejects them). Local images outside the document's directory won't render in preview.

**Sparkle + sandboxing gotchas:**
- Xcode strips `temporary-exception` entitlements during `xcodebuild archive` + export. The release script works around this by re-signing the exported app with the resolved entitlements and verifying they're present before creating the DMG.
- Verify entitlements on the **exported** app (`codesign -d --entitlements :- build/export/Clearly.app`), not the local Debug build.
- `SUEnableInstallerLauncherService` in Info.plist must stay `YES` — without it, Sparkle can't launch the installer in a sandboxed app.
- Don't copy Sparkle's XPC services to `Contents/XPCServices/` — that's the old Sparkle 1.x approach. Sparkle 2.x bundles them inside the framework.

## Testing

`swift test --package-path Packages/ClearlyCore` runs the unit suite (rendering, find/replace, outline, status bar, image-paste filename math, etc.). All tests should be green at any commit.

**What to test:** anything pure-input/pure-output in `ClearlyCore`. Parsers, renderers, sync logic, find/replace.

**What NOT to test:** SwiftUI views, `NSTextView` wrappers, WKWebView preview rendering, AppKit menu wiring. Apple's UI frameworks don't unit-test cleanly; verify those by running the app via `/verify`.

Prefer Swift Testing (`@Test`, `#expect`) for new tests. Existing XCTest suites stay — don't rewrite working tests. Per-test temp dir pattern: `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)` + `defer { try? FileManager.default.removeItem(at:) }`.

## Conventions

- All colors go through `Theme` with dynamic light/dark resolution — don't hardcode colors.
- Preview CSS in `PreviewCSS.swift` must stay in sync with `Theme` colors for visual consistency between editor and preview modes.
- CSS changes in `PreviewCSS.swift` must cover four contexts: base (light), `@media (prefers-color-scheme: dark)`, `@media print`, and the `forExport` override string. Interactive elements (copy buttons, sort indicators) should be hidden in print/export.
- **CSS source order in `PreviewCSS.swift`:** Base (light) styles for new elements must be defined BEFORE any `@media (prefers-color-scheme: dark)` overrides for those elements. If a base style comes after a dark-mode `@media` block, the base style wins by source order and dark mode breaks. Place the dark-mode override immediately after the base definition.
- Changes to `project.yml` require `xcodegen generate`. **Adding or removing source files also requires `xcodegen generate`**, even in glob-based paths — xcodegen snapshots the file list at generation time. A new file added after the last `xcodegen generate` will not be in the project until you re-run it.

### Adding preview features

Follow the `MathSupport`/`MermaidSupport`/`TableSupport`/`SyntaxHighlightSupport` pattern: create a `*Support.swift` enum in `ClearlyCore/Rendering/` with a static method that returns a `<script>` block (or empty string if the feature isn't needed for the current content). Integrate it into `PreviewView.swift`, `ClearlyQuickLook/PreviewProvider.swift`, and `PDFExporter.swift` HTML templates.

**Preview-to-editor communication.** Interactive preview features that modify source text (e.g., task checkbox toggle) use `WKScriptMessageHandler` callbacks. Register the handler, add a callback closure on `PreviewView`, and wire it in `ContentView`. When the preview modifies source text, set `coordinator.skipNextReload = true` before updating the binding — this prevents a full `loadHTMLString` flash since the DOM is already updated.

### Demo document

`Shared/Resources/demo.md` is bundled with the app and accessible via **Help → Sample Document**. Keep it updated when adding new markdown features so it serves as both a user showcase and a test fixture.
