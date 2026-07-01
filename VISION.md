# RepoBar Vision

RepoBar is a fast native maintainer cockpit. It should make repository pressure, CI, releases, and local checkout state legible without becoming a browser replacement.

## Provider rule

GitHub remains the full-featured default. Another provider belongs in core only when one bounded maintainer can keep it trustworthy:

- provider-owned API client in `RepoBarCore`, behind shared capability protocols;
- HTTPS with platform trust; no ATS exceptions, HTTP fallback, redirect token forwarding, or self-signed bypass;
- account-scoped credentials and caches; no token mirroring or cross-provider fallback;
- provider-correct repository identity, subgroup paths, web links, and checkout URLs;
- unsupported features hidden or rejected explicitly;
- regression tests plus live app and CLI proof for that provider and GitHub.

If those conditions cannot stay true, prefer a maintained fork or external integration over a partial compatibility layer in RepoBar.
