# Changelog

All notable changes to hanji are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/); this project will use
[Semantic Versioning](https://semver.org/) from its first tagged release.

## [Unreleased]

First public-ready feature set:

### Editor
- Live Preview with caret-aware marker hiding: headings, bold, italic, inline
  code, links & wikilinks, blockquotes, callouts, frontmatter, lists & tasks.
- Rendered bullets (`•`) and clickable task checkboxes (☐ / ☑), centred on the
  text they label.
- Numbered lists (`1. ` / `2) `); Return continues the list — same bullet and
  indent, numbers incrementing — and clears the marker on an empty item.
- Fenced code blocks: full-width slab background + syntax highlighting
  (Swift, JS/TS, Python, JSON, shell, with a C-like fallback).
- Inline images (`![[file]]` / `![alt](path)`), mermaid diagrams, horizontal rules.
- Editable inline file title; clickable wiki/markdown links navigate.
- Autosave (debounced, off-main) with external-edit conflict detection and a
  non-modal reload/keep banner.

### Workspace
- Full file tree (sort, multi-select, drag-and-drop, rename, trash, undo, import).
- Command palette (⌘P), quick switcher (⌘O), global FTS5 search (⇧⌘F).
- Backlinks panel and Calendar panel (right sidebar, collapsible ⌥⌘B).
- Settings: editor font size, recent vaults, live plugin toggles.

### Plugins / SDK
- Compile-time plugin SDK (`ExtensionSDK`): code-block renderers, commands +
  sidebar, workspace actions, and the `MetadataQuerying` (backlinks/index) surface.
- First-party plugins: Periodic Notes, Templater, Backlinks, Calendar, Word Count.
- Dataview-lite: `LIST`/`TABLE` with `FROM #tag`/`"folder"`, `WHERE`, `SORT`,
  frontmatter fields and `file.name` / `file.mtime` built-ins.

### Compatibility
- Opens existing markdown vaults; reads `periodic-notes` config; renders
  `<% tp.* %>` Templater syntax (core date/file functions).
