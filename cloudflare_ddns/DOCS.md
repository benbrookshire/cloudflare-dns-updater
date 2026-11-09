# Cloudflare DDNS

Every `interval_minutes` (15 by default), this app looks up your home's public IP and updates your Cloudflare DNS records to match.

- An existing record is changed only when its IP is different. Its TTL, proxy (orange cloud) setting and comment stay as they are.
- A record that doesn't exist yet is created as an A record: DNS only (not proxied), with automatic TTL.
- Every pass reads the record back from Cloudflare instead of trusting a cached value. If something else changes the record, the next pass sets it back.

## Create the API token

1. In Cloudflare, go to **My Profile → API Tokens → Create Token**, and pick **Create Custom Token**.
2. Add these permissions:
   - **Zone → Zone → Read**
   - **Zone → DNS → Edit**
3. Under **Zone Resources**, choose **Include → Specific zone → example.com**.
4. Create the token and copy it. Cloudflare shows it only once.

## Options

| Option | Default | Meaning |
|---|---|---|
| `api_token` | | The token you just created |
| `zone` | `example.com` | The domain as it appears in Cloudflare |
| `records` | `[example.com]` | Names to keep updated: `example.com`, `@`, `home`, or `home.example.com` |
| `interval_minutes` | `15` | How often to check, in minutes |
| `ipv6` | `false` | Also update AAAA records. Turn this on only if you have public IPv6 |
