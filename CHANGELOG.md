# Changelog

All notable changes to Hanji are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/); this project will use
[Semantic Versioning](https://semver.org/) from its first tagged release.

## [Unreleased]

## [0.1.0] - 2026-09-26

First public release.

### Editor
- Live Preview with caret-aware marker hiding: headings, bold, italic, inline
  code, links & wikilinks, blockquotes, callouts, frontmatter, lists & tasks.
- Rendered bullets (`•`) and clickable task checkboxes (☐ / ☑), centred on the
  text they label.
- `#tags` are recognised on their own: drawn as pills, clickable to search for
  the notes that carry them (a parent tag finds nested ones), and never taken
  from code.
- Numbered lists (`1. ` / `2) `); Return continues the list — same bullet and
  indent, numbers incrementing — and clears the marker on an empty item.
- Fenced code blocks: full-width slab background + syntax highlighting
  (Swift, JS/TS, Python, JSON, shell, with a C-like fallback).
- Inline images (`![[file]]` / `![alt](path)`), mermaid diagrams, horizontal rules.
- Editable inline file title; clickable wiki/markdown links navigate.
- Find & replace inside the open note (⌘F, ⌘G / ⇧⌘G, ⌥⌘F) via AppKit's find bar.
- Save on ⌘S, in addition to autosave.
- Autosave (debounced, off-main) with external-edit conflict detection and a
  non-modal reload/keep banner.
- Edits aren't lost quietly:
  - a failed save is reported and the note stays unsaved;
  - ⌘Q and switching vaults first save everything, and ask before dropping
    anything they couldn't save;
  - a note deleted or moved outside Hanji while it had unsaved edits stays
    open with "Save again / Close without saving";
  - tabs follow renamed and moved folders.
- Notes that aren't UTF-8 are left closed rather than opened blank.
- Nested task checkboxes toggle; checkbox toggles undo with ⌘Z.

### Workspace
- Full file tree (sort, multi-select, drag-and-drop, rename, trash, undo, import).
- Pinned tabs: a pinned tab can't be closed until unpinned, and each vault
  reopens its pinned notes (renames and moves carry the pin along).
- Command palette (⌘P), quick switcher (⌘O), global FTS5 search (⇧⌘F).
- Vault-wide find & replace (⌥⇧⌘F): literal match with an optional case
  toggle, a confirmation showing how many occurrences in how many notes, and a
  single ⌥⌘Z that reverts the whole batch.
- ⌘B shows or hides the file sidebar; the Backlinks and Calendar panels sit in
  the right sidebar (⌥⌘B).
- Settings: editor font size, recent vaults, live plugin toggles.

### Plugins / SDK
- Compile-time plugin SDK (`ExtensionSDK`): code-block renderers, commands +
  sidebar, workspace actions, and the `MetadataQuerying` (backlinks/index) surface.
- First-party plugins: Journal, Templates, Backlinks, Calendar, Word Count.
- Journal: daily, weekly, monthly, quarterly and yearly notes;
  previous/next periodic note; a Settings tab that edits the vault's
  periodic-notes config. Switching the plugin off also removes the daily notes
  Calendar opens.
- SDK surfaces for plugin settings tabs, services one plugin offers another,
  and commands that appear only when they apply.
- Queries (`dataview` code blocks): `LIST`/`TABLE` with `FROM #tag`/`"folder"`, `WHERE`, `SORT`,
  frontmatter fields and `file.name` / `file.mtime` built-ins.

### Compatibility
- Opens existing markdown vaults; reads `periodic-notes` config; renders
  the common `<% tp.* %>` template syntax (core date/file functions).

### Security
- Mermaid diagrams render from a pinned, integrity-checked mermaid.js in a web
  view that allows no fetch/XHR, no remote images, and no navigation.
- Paths that come from vault content (periodic-notes and template settings)
  can't reach outside the vault; a rename can't move a note out of its folder.
- Parsers stay linear on crafted input: a note can't freeze the editor.

[Unreleased]: https://github.com/MartianLee/hanji/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MartianLee/hanji/releases/tag/v0.1.0
