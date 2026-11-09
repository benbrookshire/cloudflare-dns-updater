# Cloudflare DDNS for Home Assistant

[![Add repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fbenbrookshire%2Fcloudflare-dns-updater)

This is a Home Assistant app (formerly called an add-on). It keeps your Cloudflare DNS records pointed at your home's public IP, checking every 15 minutes.

It doesn't trust any single web service for your IP:

- **IPv4:** your router reports its public address over UPnP, and Cloudflare or AWS has to report the same one.
- **IPv6:** the address Cloudflare reports has to be assigned to the Home Assistant machine.

If the sources disagree, DNS is left alone. [DOCS.md](cloudflare_ddns/DOCS.md) has the details.

## Requirements

- **A domain on Cloudflare** and an API token with **Zone → Zone → Read** and **Zone → DNS → Edit** on it. See [DOCS.md](cloudflare_ddns/DOCS.md#create-the-api-token).
- **Home Assistant OS or Supervised** (anything with the App store), on an amd64 or aarch64 machine.
- **A router with UPnP turned on** (needed while `router_upnp` is on, which is the default):
  - The router must be **the edge of your network**, holding the public IP itself. If an ISP box in front of it also acts as a router, the router only knows a private address. The app detects that and refuses to update.
  - **eero:** in the eero app, go to **Settings → Network settings → UPnP**. eero serves UPnP at `http://<router-ip>:1900/igd.xml`, for example `http://192.168.1.1:1900/igd.xml`.
  - If your router can't do UPnP, turn off `router_upnp`. Then Cloudflare and AWS must both answer and agree.
- **For IPv6 (optional):** public IPv6 on your network and on the Home Assistant machine.

The app uses host networking so it can find the router and see the machine's IPv6 addresses. It only makes outbound requests and opens no ports.

### Check UPnP from a computer on your network

On macOS, install the UPnP client:

```bash
brew install miniupnpc
```

On Debian or Ubuntu:

```bash
sudo apt install miniupnpc
```

Then ask the router for its status:

```bash
upnpc -s
```

Look for `ExternalIPAddress = …`. It should be your public IP, the same address shown at <https://checkip.amazonaws.com>. If no device is found, UPnP is off, or your computer is blocking local network access. On macOS, check **System Settings → Privacy & Security → Local Network**.

## Install

1. In Home Assistant, go to **Settings → Apps → App store → ⋮ → Repositories**. Add `https://github.com/benbrookshire/cloudflare-dns-updater`, or click the badge above.
2. Open **Cloudflare DDNS** and click **Install**. Home Assistant builds the image on your device, which takes a minute.
3. On the **Configuration** tab:
   - **api_token:** paste the token value.
   - **zone:** your domain, for example `example.com`.
   - **records:** `@` for the domain itself. Add others like `home` if you need them.
   - **router_upnp_url:** optional, but recommended if you know it, for example `http://192.168.1.1:1900/igd.xml` for an eero. If you leave it empty, the app finds the router automatically, and only accepts an answer from your default gateway.
   - **ipv6:** turn on only if you have public IPv6.
4. Click **Start**. Turn on **Watchdog** and **Auto update** if you want them.
5. Open the **Log** tab. A normal pass looks like this:
   ```
   A example.com is already 203.0.113.7
   ```

## Troubleshooting

| Log message | What it means |
|---|---|
| `the router didn't report its external IPv4 address over UPnP` | UPnP is off, or the router couldn't be found. Turn UPnP on, or set `router_upnp_url`. |
| `no UPnP gateway answered` | Automatic discovery failed. Set `router_upnp_url`. |
| `the router reports '192.168.x.x', which isn't a public address` | Another router is in front of yours. Put the ISP box in bridge mode, or turn off `router_upnp`. |
| `IPv4 sources disagree` | The router and an outside service gave different addresses. This can happen briefly when your IP changes, or if traffic goes through a VPN. If it keeps happening, look at the addresses in the log. |
| `no outside service confirmed the router's IPv4 address` | Cloudflare and AWS were both unreachable. The app tries again next pass. |
| `… isn't assigned to this machine; not updating AAAA` | The IPv6 address Cloudflare saw isn't on the Home Assistant machine. Its traffic may be going out through another device or a VPN. |
| `zone … not found` / `Cloudflare rejected …` | The zone name is wrong, or the token is missing a permission. |

## Switching from another updater

1. Leave the old updater running for a day, and check this app's log a few times.
2. Turn off the old updater, then revoke its API key or token in Cloudflare.

Both write the same IP, so running them side by side causes no conflict.

## Releasing an update

Home Assistant offers an update when `version` in `cloudflare_ddns/config.yaml` is higher than the version you have installed. To release a change:

1. Make the change.
2. Bump `version` in [config.yaml](cloudflare_ddns/config.yaml).
3. Add an entry to [CHANGELOG.md](cloudflare_ddns/CHANGELOG.md).
4. Push to `main`.

Changes pushed without a version bump are never offered to Home Assistant. If you don't want to wait for Home Assistant's next check, use **App store → ⋮ → Check for updates**.

## Development

```
repository.yaml          # makes this repo an app repository
cloudflare_ddns/
  config.yaml            # app manifest; `version` drives updates
  CHANGELOG.md           # shown in Home Assistant when an update is available
  build.yaml / Dockerfile
  run.sh                 # reads options and runs the loop
  ddns.sh                # one update pass (bash, curl, jq, socat)
  DOCS.md                # how the IP is checked, token setup, options
tests/                   # mock Cloudflare API, IP services and UPnP router
```

```bash
bash tests/test_ddns.sh
```

CI lints the app config, runs ShellCheck and the tests, and builds the Docker image on every push.
