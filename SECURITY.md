# Security Policy

## Reporting a Vulnerability

If you discover a security issue, please **do not open a public issue**. Email
**martionlee@gmail.com** with a description and reproduction steps. You can
expect an acknowledgement within a few days.

## Scope

Hanji is a local-first macOS app: it reads and writes markdown files in a
vault you choose and stores a per-vault search index under
`~/Library/Application Support/hanji/`. It makes no network requests except
when a note renders a `mermaid` code block, which loads a version-pinned,
integrity-checked `mermaid.js` from jsDelivr into a `WKWebView`. That page gets
the diagram text as data (never as markup), runs mermaid in strict mode, and
has a Content-Security-Policy that allows no fetch/XHR or remote images; it
cannot navigate anywhere and keeps no storage. There is no telemetry, account,
or server component.

Paths that come from vault content — for example the periodic-notes folder and
template settings — are confined to the vault. Hanji refuses to open a note it
can't decode as UTF-8 rather than risk overwriting it.
