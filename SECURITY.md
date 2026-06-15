# Security Policy

## Reporting a Vulnerability

If you discover a security issue, please **do not open a public issue**. Email
**martionlee@gmail.com** with a description and reproduction steps. You can
expect an acknowledgement within a few days.

## Scope

hanji is a local-first macOS app: it reads and writes markdown files in a
vault you choose and stores a per-vault search index under
`~/Library/Application Support/hanji/`. It makes no network requests except
when a note renders a `mermaid` code block, which loads `mermaid.js` from a CDN
in a sandboxed `WKWebView`. There is no telemetry, account, or server component.
