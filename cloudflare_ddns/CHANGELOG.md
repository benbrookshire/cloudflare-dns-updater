# Changelog

## 1.1.0

- The public IP is now checked with several independent services (5 for IPv4, 4 for IPv6) instead of the first one that answers. DNS is only updated when every service that answered agrees and at least `min_ip_sources` (default 3) answered. One bad service can't redirect your domain.
- Answers that aren't public addresses (private, loopback, CGNAT, link-local, error pages) are ignored.
- The IP is checked before Cloudflare is contacted.
- Different spellings of the same IPv6 address are treated as equal, so a record isn't rewritten for nothing.

## 1.0.1

- `zone` no longer defaults to a specific domain. It's now required, and the app stops with a clear message if it's empty.
- `records` defaults to `@` (the zone's own name).
- Existing installs keep the settings they already saved.

## 1.0.0

- First release: keeps Cloudflare A (and optionally AAAA) records matched to your public IP on a set interval.
