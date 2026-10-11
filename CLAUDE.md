# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                # Debug build
swift build -c release     # Release build
swift run MacDirStat       # Run the app
./scripts/build-app.sh     # Release build packaged as .build/MacDirStat.app (Info.plist, icon; ad-hoc signed unless SIGN_IDENTITY is set)
open Package.swift         # Open in Xcode
```

No external dependencies. Run `swift test` for scanner, cloud metadata, and size-metric regression tests. The optional live File Provider test runs only when `MACDIRSTAT_CLOUD_TEST_PATH` is set. No linter configured; Swift 6 strict concurrency mode is enforced via `swiftLanguageMode(.v6)` in Package.swift.

CI (`.github/workflows/build.yml`) runs `swift build` on a pinned `macos-26` runner for PRs and pushes to `main`. It also runs `swift test`.

Releases: pushing a `v*` tag runs `.github/workflows/release.yml`, which builds a universal app with `build-app.sh` (`UNIVERSAL=1`, `VERSION` from the tag, `SIGN_IDENTITY` = the Developer ID cert), notarizes and staples it with `scripts/notarize.sh`, and publishes `MacDirStat.zip` as a GitHub Release (stable link: `releases/latest/download/MacDirStat.zip`). Secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_API_KEY` (.p8 contents), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`.

## Architecture

MacDirStat is a native macOS (15.0+) SwiftUI disk space analyzer that visualizes directory usage as interactive treemaps. Swift 6, SPM-only, zero external dependencies.

### State & Data Flow

**AppState** (`@Observable`) is the single source of truth. It holds the scanned file tree (`rootNode: FileNode`), the current treemap view root (`treemapRoot`), selected node, and breadcrumb navigation stack. All views react to AppState changes.

Scan flow: User picks folder → **ScanCoordinator** launches **FileScanner** → FileScanner batches metadata with `getattrlistbulk`, uses `fstatat` for directory/mount identities and missing attributes, and falls back to `readdir`/`fstatat` on unsupported filesystems. It scans up to four directories in parallel with a task group and builds the **FileNode** tree itself → it streams `ScanEvent`s (`.progress`, then `.completed(root:)`) via `AsyncStream` → ScanCoordinator throttles progress updates (50ms) and hands the finished tree to AppState → treemap renders.

### Module Layout (Sources/MacDirStat/)

- **App/** — Entry point (`MacDirStatApp`) and `AppState` central state management
- **Scanning/** — `FileScanner` (parallel POSIX traversal with inode dedup, skips symlinks and other volumes, allocated size via blocks×512, thread-scoped materialization opt-out, cancellation propagation, explicit incomplete-folder reporting), `ScanCoordinator` (async orchestration, throttling, cancellation), `FileNode` (tree model with weak parent refs to avoid retain cycles, recursive aggregate computation)
- **Categorization/** — `FileCategory` (10 categories with colors/SF Symbols) and `FileExtensionMap` (~190 extension→category mappings; each extension belongs to one category, keys are lowercase)
- **Treemap/** — `TreemapLayoutEngine` in `TreemapLayout.swift` (Squarify algorithm, max 12 depth levels), `TreemapRenderer` (Canvas-based with depth-darkened category colors), `TreemapView` (hit testing; click/double-click drill-down/hover/context menu interactions), `ZoomPanOverlay` (scroll, pinch, and middle-drag zoom/pan)
- **Views/** — `ContentView` (NavigationSplitView: sidebar tree + center treemap + inspector), `WelcomeView` (volume list with usage bars, Full Disk Access banner), `ScanProgressView`, `DirectoryTreeView` (OutlineGroup), `DetailPanelView` (metadata + category breakdown)
- **Utilities/** — `ByteFormatter` (human-readable sizes), `FolderPicker` (shared NSOpenPanel), `FullDiskAccess` (permission probe and System Settings link)

### Key Patterns

- All data types crossing async boundaries are `Sendable`
- FileNode uses weak parent references to break retain cycles
- FileScanner deduplicates hard links and firmlinks by tracking seen inodes
- Menu commands reach the frontmost window through `focusedSceneValue` actions (see `OpenFolderCommands` and the zoom commands), not notifications
- Local SwiftPM builds record SDK 15.0 while CI links the macOS 26 SDK, which changes AppKit/SwiftUI behavior; test release builds from CI (or stamp a local build with `vtool -set-build-version`) before trusting a local result
- TreemapView uses Canvas for rendering (not individual SwiftUI views) for performance
- macOS APIs used: `NSWorkspace` (Reveal in Finder), `NSPasteboard` (clipboard), `NSOpenPanel` (folder picker)
