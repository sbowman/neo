# NEO for macOS (native)

A Swift / SwiftUI / AppKit rewrite of NEO for the Mac. It opens the same
`~/Documents/NEO Library` as the Electron app, in the same file format, so the
two can take turns on one library.

## Building

Requires Xcode 16 or later (macOS 14+ deployment target). No packages, no npm.

```
open macos/NEO.xcodeproj        # then ⌘R
```

or from the command line:

```
xcodebuild -project macos/NEO.xcodeproj -scheme NEO -configuration Release build
```

The project signs "to run locally". To distribute it, set a Developer ID team
in the target's Signing settings and notarize as usual.

## How it's put together

| Folder | What lives there |
|---|---|
| `App/` | App entry, menus, `AppModel` (library, shelves, import/export, email, dialogs), theme |
| `Model/` | JSON models that round-trip unknown keys, the chapter HTML codec, prose attributes |
| `Storage/` | `LibraryStore` — every file read and write, daily backups, error log |
| `Editor/` | `BookSession` (the open book: chapters, darlings, stickies, undo, search), the AppKit manuscript (`ManuscriptView`, `ChapterTextView`), SwiftUI panes, tabs, outline |
| `Shelf/` | Bookshelf, covers, dialogs |
| `Export/` | txt / md / html / pdf / docx / epub builders, the importer, PDF rendering |
| `Support/` | Zip reader/writer (Compression framework), key-aware text field, debug driver |

Each chapter is an `NSTextStorage` whose meaning — bold, italic, flags, scene
breaks, outline ghosts, alignment — is carried by NEO's own attributes; fonts
and paragraph styles are derived from them (`ProseStyler`) and never saved.
`HTMLCodec` reads and writes the same `<p>` HTML the Electron build uses.

## Differences from the Electron build

- **Covers:** every book gets one standard clothbound cover with its title and
  author; attach your own image from the right-click menu or by dropping an
  image on the book. The generated abstract covers and the OpenAI painter are
  gone. (Books that already have a `cover-*.png` show it.)
- **Spellcheck:** ⌘; toggles the system spellchecker (off by default, as before).
  Right-click a squiggle for suggestions.
- **Undo:** ⌘Z covers typing natively; chapter splits/merges/deletes, section
  breaks, darlings and replace-all use NEO's snapshot undo, as before.
- **Updates:** no auto-updater or GitHub release check (those releases are the
  Electron app).
- **macOS only.**

## Testing (Debug builds)

Debug builds accept two launch arguments:

- `-NEOLibraryPath /some/folder` — use a different library (never your real one while testing)
- `-NEODebugScript /path/script.txt` — run a script of UI actions (`open`, `type`,
  `key return`, `cmd z`, `select`, `dump`, `shot`, `export`, …) against the live
  app. See `Support/DebugDriver.swift` for the full list.
