# Hanji — Find & Replace

**Decision record**, written alongside the implementation (unlike the earlier
records in this folder, which were specs written first). Documents what was
built and, more usefully, what was deliberately *not* built.

**Goal:** three gaps found in the pre-release audit — no in-note find, no ⌘S,
and no way to rename a term across a whole vault.

## Scope

| | Shipped |
|---|---|
| In-note find/replace | AppKit's find bar (⌘F, ⌘G / ⇧⌘G, ⌥⌘F) |
| Save | ⌘S, alongside the existing autosave |
| Vault-wide replace | ⌥⇧⌘F, in the search sidebar |

## Decisions

**In-note find is AppKit's, not ours.** `NSTextView.usesFindBar` gives search,
replace, incremental highlight and the whole keyboard vocabulary for two lines.
The one risk was `LivePreviewStyler.apply`, which resets attributes across the
entire document on every caret move and would erase anything the find bar drew.
It doesn't: NSTextFinder's match highlight rides on *temporary* attributes,
which live outside the text storage. Verified live, not just by reading.

SwiftUI has no menu items for this, so `HanjiApp` sends
`performTextFinderAction(_:)` to the responder chain with the action in the
sender's `tag` — the same protocol AppKit's own Edit menu uses.

**Vault replace is literal, never regex.** A regex typo across a whole vault is
unrecoverable in a way a literal typo is not. `TextReplace` scans with
`NSString.range(of:options:.literal)`, non-overlapping, UTF-16 offsets to match
the rest of the editor. Case sensitivity is a per-call flag (`Aa` in the UI).

**One undo entry for the whole batch.** `FileOperation.replaced` carries every
rewritten file's previous text, so ⌥⌘Z restores all of them. Per-file entries
were rejected: a vault left half-replaced after one ⌥⌘Z is worse than no undo.
There is a headless check that fails if the batching is broken.

**Count on demand, not per keystroke.** Scanning every note on each character
would stall the sidebar, and the app already carries "async search for large
vaults" as known debt. Instead `previewReplaceInVault` runs when the user
presses Replace All, and its result *is* the confirmation dialog — so nobody
fires a vault-wide rewrite without seeing its size first.

**Open tabs go through the existing reconcile path.** `replaceInVault` flushes
the open note's unsaved buffer first (so those edits are replaced rather than
clobbered), then calls `reloadTree()`. `reconcileTabs()` already refreshes clean
tabs from disk and raises the conflict banner for dirty ones — no new tab-state
code, and no way for a stale buffer to overwrite the replacement on next save.

## Not built

Regex, per-occurrence review/step-through, replace scoped to a folder or to the
current search results, and a dry-run diff. All are additive on top of
`TextReplace` if they turn out to be wanted.

## Verification

`TextReplace` (14 assertions) and `VaultReplace` (18) in `swift run Checks`;
both mutation-tested — dropping the pre-flush, and switching batch undo to
per-file entries, each turn assertions red. The find bar, the ⌥⇧⌘F panel and
its two-row sidebar layout were confirmed on the running app.
