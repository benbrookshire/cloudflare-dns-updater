# Changelog

## 1.0.1

- `zone` no longer defaults to a specific domain. It's now required, and the app stops with a clear message if it's empty.
- `records` defaults to `@` (the zone's own name).
- Existing installs keep the settings they already saved.

## 1.0.0

- First release: keeps Cloudflare A (and optionally AAAA) records matched to your public IP on a set interval.
