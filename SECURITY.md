# Security Policy

## Supported Versions

Security fixes are applied to the current default branch before the next MELPA
release.  Until the first stable release, only the latest unreleased development
state is supported.

## Reporting a Vulnerability

Do not report vulnerabilities with exploit details in a public issue.

Use GitHub's private vulnerability reporting for this repository when available.
If private reporting is not available, open a minimal public issue asking for a
private contact channel and omit reproduction details, tokens, payloads, local
paths, screenshots, and logs.

Useful private report content:

- affected commit or version
- operating system and Emacs version
- minimal reproduction steps
- expected and actual security boundary
- impact assessment
- whether the issue is already public

## Security Model

doclive starts a local HTTP server for preview rendering.  The default bind host
is `127.0.0.1`, and preview routes require a per-session token.  Treat preview
URLs as bearer secrets.  After the initial authorized page load, the browser
runtime removes the token query parameter from the visible URL and history.

The preview intentionally renders user-controlled Markdown and Org content in a
browser context.  The implementation therefore relies on:

- route-level token checks
- loopback binding by default
- strict request parsing
- Content-Security-Policy generated from configured browser asset origins
- response-local CSP nonces that are separate from bearer tokens
- pinned default browser assets
- HTML sanitization before preview insertion
- URL attribute allowlisting before preview insertion
- local linked-document confinement under the source directory by default
- disabled local-variable evaluation for linked documents
- token invalidation when the preview server stops
- preview entry, SSE client, and update-timer cleanup when `doclive-preview-mode`
  is disabled for a buffer

Reports that bypass or weaken these boundaries are security bugs.

Rendered document URL attributes are kept only for relative links, anchors, and
explicit `http:`, `https:`, or `mailto:` URLs.  Unsupported schemes,
protocol-relative URLs, backslashes, and control/space-folded forms are removed
before DOM insertion.

## Disclosure

The project aims to acknowledge private reports promptly, prepare a fix on the
default branch, and document user-visible impact in `NEWS.org`.  Public
disclosure should wait until a fix is available unless there is active
exploitation or a broader ecosystem reason to disclose sooner.
