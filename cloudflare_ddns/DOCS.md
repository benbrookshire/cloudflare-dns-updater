# Cloudflare DDNS

Every `interval_minutes` (15 by default), this app looks up your home's public IP and updates your Cloudflare DNS records to match.

- An existing record is changed only when its IP is different. Its TTL, proxy (orange cloud) setting and comment stay as they are.
- A record that doesn't exist yet is created as an A record: DNS only (not proxied), with automatic TTL.
- Every pass reads the record back from Cloudflare instead of trusting a cached value. If something else changes the record, the next pass sets it back.

## How the public IP is checked

Each pass checks your public IP against a local source on your own network and against outside services. DNS only changes when they all agree.

**IPv4**
- **Your router, over UPnP.** The router holds your public IPv4 address, so this is the main source. While `router_upnp` is on, the router has to answer, or nothing is updated.
- **Outside services:** Cloudflare and AWS. At least one of them has to answer and match the router.

**IPv6**
- **Outside service:** Cloudflare reports the address your traffic comes from.
- **This machine.** IPv6 has no NAT, so your AAAA record is the Home Assistant machine's own address. The address Cloudflare reports has to be one assigned to this machine.

Any disagreement, any answer that isn't a public address (private, loopback, CGNAT, or an error page), or a router that reports a private address means DNS is left alone until the next pass. The log shows every answer it got. A router reporting a private address usually means there's a second router in front of it.

So a compromised outside service can't redirect your domain. The worst it can do is delay an update. This also catches traffic going out through a VPN.

### Router setup

- Turn on UPnP in the router. On an eero, that's **Settings → Network settings → UPnP** in the eero app.
- The app finds the router automatically, and only trusts an answer that comes from your default gateway. If automatic discovery doesn't work, set `router_upnp_url` to the router's description URL. For an eero at `192.168.1.1`, that's `http://192.168.1.1:1900/igd.xml`.
- If your router doesn't hold the public IP itself, turn off `router_upnp`. For example, it might be behind an ISP box that also acts as a router. With `router_upnp` off, both Cloudflare and AWS must answer and agree.

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
| `router_upnp` | `true` | Require the router to confirm its public IPv4 address over UPnP |
| `router_upnp_url` | (empty) | Router's UPnP description URL. Leave empty to find it automatically |

The app uses host networking so it can find the router and see this machine's IPv6 addresses. It only makes outbound requests and doesn't open any ports.
