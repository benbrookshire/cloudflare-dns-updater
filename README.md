# Cloudflare DDNS for Home Assistant

[![Add repository to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fbenbrookshire%2Fcloudflare-dns-updater)

This is a Home Assistant app (formerly called an add-on). It keeps `example.com` pointed at your home's public IP by checking every 15 minutes. It uses only bash, curl and jq.

```
repository.yaml          # makes this repo an app repository
cloudflare_ddns/
  config.yaml            # app manifest; `version` drives updates
  CHANGELOG.md           # shown in Home Assistant when an update is available
  build.yaml / Dockerfile
  run.sh                 # reads options and runs the loop
  ddns.sh                # one update pass (can be run on its own)
  DOCS.md                # how to make the token, option reference
tests/                   # mock Cloudflare API + tests, run in CI
```

## Install

1. In Home Assistant, go to **Settings → Apps → App store → ⋮ → Repositories**. Add `https://github.com/benbrookshire/cloudflare-dns-updater`, or click the badge above.
2. Open **Cloudflare DDNS**, then click **Install**. Home Assistant builds the image on your device, which takes a minute.
3. On the **Configuration** tab, paste your API token (just the token value) and set **zone** to your domain, e.g. `example.com`. See [DOCS.md](cloudflare_ddns/DOCS.md) for how to create the token.
4. Click **Start**, and turn on **Watchdog** and **Auto update** if you want them.
5. Open the **Log** tab. You should see either `A example.com is already <ip>` or `Updated A example.com: ...`.

## Releasing an update

Home Assistant checks the repository periodically. It offers an update when `version` in `cloudflare_ddns/config.yaml` is higher than the version you have installed. To release a change:

1. Make the change.
2. Bump `version` in [config.yaml](cloudflare_ddns/config.yaml), for example `1.0.0` → `1.0.1`.
3. Add an entry to [CHANGELOG.md](cloudflare_ddns/CHANGELOG.md).
4. Push to `main`.

Changes pushed without a version bump are never offered to Home Assistant. If you don't want to wait, use **App store → ⋮ → Check for updates**.

## Retiring the old updater

1. Leave the old device running for a day, and check the app log a few times.
2. Turn off DDNS on the old device. Then revoke its API key or token in Cloudflare.

While both are running, they write the same IP, so they won't fight each other.

## Development

```bash
bash tests/test_ddns.sh   # runs ddns.sh against a mock Cloudflare API
```

CI lints the app config, runs ShellCheck and the tests, and builds the Docker image on every push.
