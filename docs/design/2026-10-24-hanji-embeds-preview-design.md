# Hanji — Note Embeds and Link Previews

Design doc · 2026-10-24

**Goal:** `![[Note]]` on its own line shows that note, rendered, where the
embed is; hovering a link shows the note it points to in a popover. Third of
three pieces from the Obsidian comparison.

## Decisions

**One renderer for both: `RenderedText`.** A note's Markdown turned into an
attributed string the way reading mode shows it, but with the markers
removed rather than collapsed — `- ` becomes `•`, `- [ ] ` `☐`, fence lines
and frontmatter go. It uses the editor's tokenizer and `LivePreviewStyler`,
so an embed reads like the note itself. Only text: code blocks, tables, math
and images inside an embedded note show as styled source, and an embed inside
an embed is just its name — no recursion, no widgets inside widgets.

**Embeds are widgets.** An own-line `![[Note]]` naming a note (no extension,
or `.md`) becomes a widget like an image or a table: the caret on the line
shows the source, a click there puts the caret in it. `ImageParser` already
finds own-line `![[…]]`; a new `NoteEmbeds` keeps the ones that name notes.

**The editor asks the app for notes.** `MarkdownEditorView` gains
`notePreview: (String) -> NotePreview?` — given a link target, the note's
title and text (an open tab's unsaved text included). The app resolves it with
`LinkTarget`, the rule links use.

**Previews follow Obsidian.** In editing, a preview needs ⌘ held while the
pointer rests on a link; in reading mode resting is enough. 0.5 s delay.

## Behaviour

### Embeds

- `![[Note]]`, `![[Note|alias]]`, `![[Note.md]]`: the whole note.
  `![[Note#Heading]]`: that heading's section (up to the next heading of the
  same or a higher level); a heading that isn't there shows the whole note.
- A card: the note's title on top, the rendered text below, an accent bar on
  the left; at most 400 pt tall, cut off with a fade when longer.
- A target that isn't a note in the vault: a card saying so.
- The card updates when the note it shows changes (its text is part of the
  widget's identity).

### Link previews

- Any wikilink or markdown link to a note (not an embed, not a URL), when the
  target exists. A `#heading` in the link shows that section.
- Shown after the pointer rests 0.5 s on the link — with ⌘ held while editing
  (pressing ⌘ while already resting counts); in reading mode without.
- A popover below the link: title and rendered text, 360 pt wide, up to
  320 pt tall, scrolling.
- Closes when the pointer leaves both the link and the popover (after a short
  grace period, so it can be reached), on typing, scrolling or clicking, and
  when another link takes its place.

## Design

### MarkdownCore

- `NoteEmbeds.embeds(in:) -> [NoteEmbed]` (`target`, `heading`, `line`).
- `NoteEmbeds.section(_ heading: String, in text: String) -> String?`.
- `NoteEmbeds.heading(inLink:)` — the `#heading` of a link's source text.

### EditorEngine

- `RenderedText.attributed(_ markdown: String) -> NSAttributedString`.
- `NotePreview` (`title`, `text`), `MarkdownEditorView.notePreview`.
- `NoteCardView` (SwiftUI): title + rendered text; used by the embed widget
  and the popover.
- `Coordinator.noteEmbedWidgets` in the widget pass.
- Hover: `ClickableTextView` tracks the pointer (`mouseMoved`,
  `flagsChanged`, `mouseExited`) and reports `(offset?, modifiers)`;
  `Coordinator.hover(at:modifiers:)` decides, times and shows the popover;
  `isPreviewShown` for checks.

### AppCore / HanjiApp

- `AppState.notePreview(for:) -> NotePreview?`; `ContentView` passes it.

## Testing

- `NoteEmbeds`: note vs image embeds, alias, `.md`, heading, section bounds.
- `RenderedText`: markers gone, bullets/boxes, fences and frontmatter gone,
  heading font kept.
- Editor harness: an embed line becomes a widget showing the note; the caret
  on it brings the source back; a missing note shows the not-found card.
- Editor harness: `hover(at:modifiers:)` shows a popover after the delay with
  ⌘ while editing, not without; without ⌘ in reading mode; leaving the link
  closes it; typing closes it.
- Perf groups unchanged.
- GUI: a screenshot of a note with an embed.
