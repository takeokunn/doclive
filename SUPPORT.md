# Support

Use the smallest public channel that matches the request, and keep security
details out of public reports.

## Questions and Usage Help

Open a GitHub Discussion or issue with:

- operating system
- Emacs version
- whether Emacs was built with xwidget WebKit support
- document type, Markdown or Org
- the exact command you ran
- relevant console or `*Messages*` output with local paths and tokens removed

## Bug Reports

For non-security bugs, open a GitHub issue with a minimal reproduction.  Include:

- affected commit or release
- steps to reproduce from `emacs -Q`
- expected behavior
- actual behavior
- whether `make check` passes locally, if you have a checkout

## Feature Requests

Open a GitHub issue describing the workflow and the security or maintenance
tradeoff.  Requests that broaden local file access, execute document code, fetch
remote files, or weaken the browser security model need an explicit threat-model
justification.

## Security Reports

Do not include exploit details, tokens, local file paths, screenshots, or logs in
public issues.  Follow `SECURITY.md` for private vulnerability reporting.
