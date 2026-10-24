# Hanji — Links Follow Renames, and Unlinked Mentions

Design doc · 2026-10-24 · issue #12

**Goal:** renaming or moving a note (or a folder) rewrites every link to it
across the vault, and the backlinks panel lists notes that mention the note
by name without linking, with a button that turns a mention into a link.
Second of three pieces from the Obsidian comparison.

## Decisions

**Automatic, with a status message and one undo.** No confirmation: the
links are rewritten as part of the rename, the status bar says "Updated 5
links in 3 notes" for a few seconds, and ⌥⌘Z undoes the rename and the
rewrites together. Rejected: asking first (an extra dialog on every rename),
a setting (no one has asked to keep stale links).

**One resolution rule.** `LinkTarget.resolve` (MarkdownCore) is the rule
`openLink` already applies — a target names a note by vault-relative path or
by file name, without `.md`, ignoring case, first note in file order wins —
moved out of `AppState` so the editor's clicks, the rewrite and the mention
button can't disagree. A link is rewritten only when, before the rename, it
resolved to a note that moved.

**Whole-vault scan, like vault-wide replace.** Every note is read and the
changed ones written through `Vault.write`, after `settleSaves()`, followed
by `reloadTree()` so open tabs reconcile (a dirty tab raises the usual
conflict banner). Not from the search index: it lags behind unsaved edits
and doesn't store link positions for every form. A cheap `contains` check on
the old names skips most notes without parsing.

**Mentions from the index, checked against the file.** Candidates come from
the search index (FTS trigram, LIKE for 1–2 characters); each candidate's
file text is then searched exactly, so offsets are those of the file the
button will edit.

## Behaviour

### Rewriting

- **Forms kept:** `[[Plan]]` → `[[Roadmap]]`; `[[Projects/Plan]]` →
  `[[Projects/Roadmap]]`; `[[Plan#Goals|the plan]]` keeps `#Goals` and the
  alias; `![[Plan]]` embeds too; a `.md` written in a wikilink stays.
  Markdown links `[t](Projects/Plan.md#x)` keep their form (path or bare
  name, a leading `./`, the anchor); spaces in a new destination are written
  `%20`.
- **Moves:** a bare-name link still resolves after a move and is left alone;
  path-form links get the new path.
- **Folders:** renaming or moving a folder maps every note inside it.
- **Name clashes:** if a bare name would now resolve to a different note
  (another note already has the new name), the link is written in path form.
- **Not touched:** links in code (fenced or inline), external URLs, links
  that resolved to some other note before the rename, image embeds.
- **The renamed note itself:** its own links to itself are rewritten too.
- **Status message:** "Updated N links in M notes" (singulars as needed) in
  the status bar for 4 s; nothing when no link changed.
- **Undo:** ⌥⌘Z restores each rewritten note whose text is still exactly what
  the rewrite wrote (one edited since keeps its newer text, as with replace),
  then moves the note back.

### Unlinked mentions

- **Where:** a collapsible "Unlinked mentions" group under the backlinks list
  (collapsed by default, with a count).
- **What counts:** the note's name (file name without `.md`), ignoring case,
  in another note's text, not inside code, frontmatter or a link. Before the
  name there must be no letter or digit; after it no ASCII letter or digit —
  so "Plan" isn't found in "Planning", but "한지" is found in "한지는".
- **Each row:** the source note's title and a snippet with the mention
  highlighted; clicking the row opens the note; a **Link** button rewrites
  that one mention to `[[Name]]` — `[[Name|text]]` when the text's case
  differs, and path form when the name is shared by another note.
- **Link button writes** like vault-wide replace (saves first, atomic write,
  tabs reconcile) and is undoable with ⌥⌘Z. If the note changed so the mention
  is no longer at that place, nothing is written and the list refreshes.
- **Limit:** at most 50 notes are listed.

## Design

### MarkdownCore

- `LinkTarget` (new): `resolve(_ target: String, in paths: [String]) -> String?`
  over vault-relative paths with `.md`, in file order.
- `LinkRewrite` (new): `rewrite(_ text: String, moves: [String: String],
  before: [String], after: [String]) -> (text: String, count: Int)` — `moves`
  maps old → new vault-relative paths.
- `Mentions` (new): `unlinked(of name: String, in text: String) -> [Range<Int>]`.
- `LinkParser`: `markdownLinks` becomes internal so `LinkRewrite` reuses it.

### AppCore

- `AppState.rename` / `move`: build `moves` (one note, or every note under a
  folder), rewrite, record `.renamed(from:to:links:)` / `.moved(from:to:links:)`
  carrying the rewritten files' before/after texts, set `status`.
- `AppState.status: String?` (published; cleared after 4 s).
- `AppState.linkMention(sourcePath:range:targetPath:) -> Bool`.
- `openLink` resolves through `LinkTarget`.
- `Host`: `unlinkedMentions(ofNoteAt:)`, `linkMention(…)`.

### MKSearchKit

- `SearchIndex.notes(containing:limit:) -> [(path: String, title: String)]`.

### ExtensionSDK

- `MetadataQuerying.unlinkedMentions(ofNoteAt:) -> [SDKMention]`;
  `WorkspaceActions.linkMention(sourcePath:range:targetPath:) -> Bool`;
  `SDKMention` (path, title, snippet, match ranges, range in the note).

### UI

- `BacklinksPlugin`: the "Unlinked mentions" group.
- `ContentView.statusBar`: shows `appState.status` on the left (the bar also
  appears for it when no plugin status item is shown).

## Testing

- `LinkTarget`: path vs name, case, `.md`, first-in-order on a shared name.
- `LinkRewrite`: every form above; alias/anchor kept; embeds; code skipped;
  other-note links untouched; clash → path form; folder map; `%20`; count.
- `Mentions`: boundaries (English and Korean), case, code/link/frontmatter
  excluded.
- AppState on a temp vault: rename and move rewrite links and set `status`;
  folder rename; ⌥⌘Z restores names and texts, skipping a note edited since;
  a dirty open tab is saved before the rewrite; `linkMention` writes, undoes,
  and refuses a stale range.
- GUI: rename a note from the tree, see the status message and a linking
  note updated; the mentions group in the backlinks panel.
