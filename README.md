# Jellyfin on Railway

[Jellyfin](https://jellyfin.org) — the free software media system — packaged for
[Railway](https://railway.com). The upstream `jellyfin/jellyfin` image is used
unchanged; this repo adds a boot adapter for the handful of things Railway needs
that no Jellyfin environment variable can express.

## What the adapter does

| At boot | Why |
|---|---|
| Folds `config`, `cache` and `media` onto one mount | A Railway service gets exactly one volume, and Jellyfin defaults to two separate paths |
| Completes the setup wizard from variables | A fresh deployment is otherwise claimable by whoever reaches the URL first |
| Trusts Railway's edge as a proxy | Without it Jellyfin records the proxy address as every client's IP and never sees `https` |
| Caps ffmpeg's thread count at the container's CPU quota | Jellyfin passes `-threads 0`, and ffmpeg then sizes itself from the host's core count |

Everything except the directory setup is gated on the setup wizard still being
incomplete, so a redeploy never rewrites settings an operator changed later.

## Variables

None are required — every one has a working default.

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8096` | Must stay `8096`; Jellyfin's listen port lives in `network.xml`, not in the environment |
| `JELLYFIN_ADMIN_USERNAME` | `admin` | Administrator created on first boot |
| `JELLYFIN_ADMIN_PASSWORD` | — | Administrator password. Leave empty to run Jellyfin's own setup wizard by hand instead |
| `JELLYFIN_SERVER_NAME` | `Jellyfin` | Server name shown to clients |
| `JELLYFIN_MEDIA_DIR` | `/data/media` | Media root; `movies/`, `shows/` and `music/` are created under it and registered as libraries |
| `JELLYFIN_DATA_DIR` | `/data/config` | Jellyfin's data directory |
| `JELLYFIN_CACHE_DIR` | `/data/cache` | Image and transcode cache |
| `JELLYFIN_TRUSTED_PROXIES` | `100.64.0.0/10,152.233.0.0/17` | Railway's container-facing CGNAT range and its public edge range |
| `JELLYFIN_ENCODING_THREADS` | container CPU quota | Override the ffmpeg thread cap |
| `JELLYFIN_BOOTSTRAP` | `true` | Set to `false` to skip first-run setup entirely |

## Adding media

The volume is the library. Upload into it with the Railway CLI:

```bash
railway volume files upload ./my-film.mkv /media/movies/my-film.mkv --volume jellyfin-data
```

Then **Dashboard → Libraries → Movies → Scan Library**. `railway volume browse /`
opens the same volume in an interactive file browser.

## Notes

- Hardware transcoding is unavailable — Railway exposes no GPU or VA-API device,
  so every transcode is CPU-only. Direct play, which most clients can do for
  common formats, does not transcode at all.
- Jellyfin's autodiscovery is switched off: it needs inbound UDP, which Railway
  does not route. Clients connect by URL.
- Jellyfin has no public sign-up; accounts are created by an administrator from
  Dashboard → Users.
