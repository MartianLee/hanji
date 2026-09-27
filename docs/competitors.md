# Competitor comparison

Measurements of Hanji against other Markdown editors, recorded as they're
taken. Each entry states how it was measured so later runs can be compared
like for like.

## Memory — Hanji vs Obsidian (2026-09-28)

| | Hanji 0.1.0 (194) | Obsidian 1.12.4 |
|---|---|---|
| **Total** | **100 MB** | **≈ 424 MB** |
| Processes | 1 (`hanji`) | 4: Renderer 249 MB · GPU 91 MB · main 76 MB · Helper 7.7 MB |

**How it was measured.** `footprint -p <pid>` (physical footprint, the same
figure as Activity Monitor's *Memory* column), summed over every process the
app runs. Both apps were idle at the time. Machine: Apple M5 Pro, 48 GB,
macOS 26.6.2.

**Caveats.**

- The two apps weren't running the same vault. Obsidian had its iCloud vault
  (~2,770 notes) open and had been running for ~32 days; Hanji had been
  running for ~10 minutes, and which vault it had open wasn't recorded. A fair
  rerun opens the same vault in both apps with the same notes showing.
- RSS (`ps`) is higher than footprint for both apps (Hanji 216 MB; Obsidian
  ≈ 665 MB summed) because it counts shared framework pages. Compare
  footprints, not RSS.

## CPU — not yet measured

At idle both apps sat at 0.0% (six `top` samples, 2 s apart), which doesn't
tell them apart. Averages over the whole run can't be compared either: Hanji
had only been running for ~10 minutes, so launch cost dominates its number.
To do: measure CPU while both apps do the same work on the same vault (open a
large note, type quickly, scroll).
