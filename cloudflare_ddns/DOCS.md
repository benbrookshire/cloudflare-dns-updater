# Cloudflare DDNS

Every `interval_minutes` (15 by default), this app looks up your home's public IP and updates your Cloudflare DNS records to match.

- An existing record is changed only when its IP is different. Its TTL, proxy (orange cloud) setting and comment stay as they are.
- A record that doesn't exist yet is created as an A record: DNS only (not proxied), with automatic TTL.
- Every pass reads the record back from Cloudflare instead of trusting a cached value. If something else changes the record, the next pass sets it back.

## How the public IP is checked

On every pass, the app asks several independent services for your public IP:

- **IPv4:** Cloudflare, AWS, ipify, ipinfo and ident.me
- **IPv6:** Cloudflare, ipify, ipinfo and ident.me

DNS is only updated when **every service that answered gives the same address**, and at least `min_ip_sources` of them answered (3 by default). A service that doesn't answer is skipped. So is one that answers with something that isn't a public address, such as a private, loopback or CGNAT address, or an error page.

If the services disagree, the app logs every answer and leaves DNS alone until the next pass. This means a compromised or misbehaving service can delay an update, but it can't redirect your domain. It also catches the case where Home Assistant's traffic goes out through a VPN, since VPN providers often use different exit IPs for different connections.

## Create the API token

1. In Cloudflare, go to **My Profile → API Tokens → Create Token**, and pick **Create Custom Token**.
2. Add these permissions:
   - **Zone → Zone → Read**
   - **Zone → DNS → Edit**
3. Under **Zone Resources**, choose **Include → Specific zone →** your domain.
4. Create the token and copy it. Cloudflare shows it only once.

## Options

| Option | Default | Meaning |
|---|---|---|
| `api_token` | | The token you just created |
| `zone` | (required) | The domain as it appears in Cloudflare, e.g. `example.com` |
| `records` | `["@"]` | Names to keep updated: `@` (the domain itself), `home`, or `home.example.com` |
| `interval_minutes` | `15` | How often to check, in minutes |
| `ipv6` | `false` | Also update AAAA records. Turn this on only if you have public IPv6 |
| `min_ip_sources` | `3` | How many IP services must answer, and all agree, before DNS is changed (2–4) |
