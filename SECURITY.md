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
is `127.0.0.1`.  Initial preview URLs use a short-lived, single-use bootstrap code
rather than the long-lived session token.  A valid bootstrap request sets a
`doclive-token` cookie with `HttpOnly` and `SameSite=Strict`, then redirects to a token-free preview URL.
The cookie intentionally omits `Secure` because the preview server is plain HTTP
and loopback-only by default; users who opt into a non-loopback bind host must
treat that network path as trusted or add their own transport protection.
Subsequent `/content`, `/open`, and `/events` requests
are authorized by that cookie instead of a query token.  Requests containing a
`token` query parameter are rejected even when the cookie is valid.
Preview buffer IDs that appear in URLs, SSE streams, and JSON payloads are
opaque per-buffer random routing identifiers.  They are not authentication
secrets and are not derived from local file paths or buffer names.

Binding to a non-loopback host requires changing `doclive-host` and explicitly
setting `doclive-allow-non-loopback-host` to non-nil.

The preview intentionally renders user-controlled Markdown and Org content in a
browser context.  The implementation therefore relies on:

- route-level cookie checks
- loopback binding by default
- explicit opt-in for non-loopback bind hosts
- strict request parsing
- Content-Security-Policy generated from configured browser asset origins
- response-local CSP nonces that are separate from the session cookie
- HttpOnly preview-session cookies after the initial authorized load
- pinned default browser assets
- HTML sanitization before preview insertion
- URL attribute allowlisting before preview insertion
- local linked-document confinement under the source directory by default,
  checked after symlink resolution
- disabled local-variable evaluation for linked documents
- token invalidation when the preview server stops
- preview entry, SSE client, and update-timer cleanup when `doclive-preview-mode`
  is disabled for a buffer

Reports that bypass or weaken these boundaries are security bugs.

Linked Markdown and Org documents are confined by their resolved real paths by
default.  A symlink inside the source directory that points outside the source
directory is therefore rejected unless `doclive-allow-linked-document-parent-directory`
is explicitly enabled for trusted documents.

Rendered document URL attributes are kept only for relative links, anchors, and
explicit `http:` or `https:` URLs.  `mailto:` is allowed only for `href` and
`xlink:href`.  Unsupported schemes, protocol-relative URLs, backslashes, and
control or whitespace-bearing forms are removed before DOM insertion.  `srcset`
is removed before DOM insertion because it is a compound URL list.  `ping` is
removed before DOM insertion to avoid link-click side effects from rendered
content.

## Disclosure

The project aims to acknowledge private reports promptly, prepare a fix on the
default branch, and document user-visible impact in `NEWS.org`.  Public
disclosure should wait until a fix is available unless there is active
exploitation or a broader ecosystem reason to disclose sooner.
