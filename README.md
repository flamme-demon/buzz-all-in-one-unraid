# Buzz all-in-one for Unraid

***English** · [Français](README.fr.md)*

[Buzz](https://github.com/block/buzz) is a self-hosted workspace, built by Block, where humans and AI agents collaborate in shared rooms: messages, code reviews, workflow steps and git events are all signed Nostr events in a single audit log.

The Buzz relay is a Rust binary that needs three external services:

| Service | Role |
| --- | --- |
| PostgreSQL 17 | event storage and full-text search |
| Redis | pub/sub and presence |
| S3 (MinIO) | media storage (Blossom protocol) |

This repository bundles them into **a single Docker image**, supervised by [s6-overlay](https://github.com/just-containers/s6-overlay), to fit Unraid's "one container, one app" model — instead of a four-container stack to wire up by hand.

The relay binaries are not rebuilt: they are taken as-is from the official `ghcr.io/block/buzz` image, pinned by digest in [`versions.env`](versions.env).

## Installing on Unraid

### 1. Get the image

The image is published by this repository's CI:

```
ghcr.io/flamme-demon/buzz-all-in-one-unraid:latest
```

To build it yourself, from an Unraid terminal:

```bash
git clone https://github.com/flamme-demon/buzz-all-in-one-unraid.git
cd buzz-all-in-one-unraid
./build.sh
```

### 2. Add the container

Copy [`templates/buzz-aio.xml`](templates/buzz-aio.xml) into `/boot/config/plugins/dockerMan/templates-user/`, then, in Unraid's **Docker** tab, *Add Container* → pick `buzz-aio` from the user templates list.

Otherwise, create the container by hand using the settings table below.

### 3. Set the two variables that matter

**`RELAY_URL`** — the address your clients actually use to reach the relay, for example `ws://192.168.1.10:3000`, or `wss://buzz.example.com` behind a reverse proxy. It is used in NIP-42 authentication challenges: if it doesn't match, clients connect but then fail to authenticate, which is a confusing symptom ("connected" yet nothing works).

**`RELAY_OWNER_PUBKEY`** — your Nostr public key, as 64 lowercase hex characters (not an `npub1…`). It enables relay membership enforcement. Copy it from the Buzz client after creating your identity.

> While `RELAY_OWNER_PUBKEY` is empty, the relay starts in **open mode**: anyone who can reach it can write to it. This is a deliberate trade-off — enforcing membership without knowing the operator's key would lock everyone out, including you. The container says so in its logs on every start. Do not expose the container beyond your local network in this state.

### 4. Start it

The first start initialises the Postgres cluster, generates secrets and runs the migrations: expect one to two minutes. The web UI then answers on `http://<unraid-ip>:3000/index.html`, and Buzz desktop clients connect over WebSocket at the same address.

> The URL does end in `/index.html`: current relay versions serve the web bundle from that route and `/assets/*`, but answer 404 on the bare root. The Unraid template points the *WebUI* button there accordingly.

## Settings

| Variable | Default | Role |
| --- | --- | --- |
| `RELAY_URL` | `ws://localhost:3000` | public relay address (NIP-42) |
| `RELAY_OWNER_PUBKEY` | *(empty)* | operator public key, 64 hex chars |
| `PUID` / `PGID` | `99` / `100` | ownership of files under `/config` |
| `TZ` | `Europe/Paris` | container timezone |
| `BUZZ_REQUIRE_AUTH_TOKEN` | `true` | authentication required on the REST API |
| `BUZZ_REQUIRE_MEDIA_GET_AUTH` | `true` | authentication required to read media |
| `BUZZ_CORS_ORIGINS` | *(empty)* | allowed browser origins, comma-separated |
| `RUST_LOG` | `buzz_relay=info,…` | log verbosity |

Any variable the relay understands (see the [upstream `.env.example`](https://github.com/block/buzz/blob/main/.env.example)) can be added to the container and is passed straight through. Only `DATABASE_URL`, `REDIS_URL` and the `BUZZ_S3_*` variables are imposed by the image, since they point at the bundled services.

### Ports

| Port | Use |
| --- | --- |
| 3000 | web UI, REST API, WebSocket — **the only one to publish** |
| 9000 | MinIO's S3 API, optional: the relay serves `/media` itself |
| 8080 | `/_liveness` and `/_readiness` probes, container-internal |
| 9102 | Prometheus metrics, container-internal |

To expose metrics, publish port 9102 in the template.

## Data and backups

Everything lives under `/config` (by default `/mnt/user/appdata/buzz`):

```
/config
├── secrets.env    relay Nostr identity + internal passwords
├── postgres/      database
├── minio/         media
├── git/           NIP-34 repositories
├── git-packs/     git pack cache (rebuildable)
└── redis/         pub/sub snapshot (rebuildable)
```

`secrets.env` is generated on first start and holds `BUZZ_RELAY_PRIVATE_KEY`, **the relay's Nostr identity**. Losing it changes the relay's identity as every client sees it: back this file up, and if you restore, restore it along with the rest of `/config`.

## Updates

`versions.env` is the source of truth for everything bundled. The [`watch-upstream.yml`](.github/workflows/watch-upstream.yml) workflow checks it daily and updates, where applicable:

- the digest of `ghcr.io/block/buzz:latest` (the relay itself);
- s6-overlay, MinIO and the `mc` client.

A change is committed to `main`, which re-runs [`build.yml`](.github/workflows/build.yml). That workflow **starts the image and waits for `/_readiness` to go green before publishing**: an upstream version that doesn't come up with this stack blocks the release instead of breaking installs. A weekly rebuild additionally picks up Debian security fixes.

Postgres stays pinned to 17: a major version change would require migrating the existing cluster, which must remain a manual decision.

On Unraid, updating is the container's usual button. Schema migrations run automatically on start (`BUZZ_AUTO_MIGRATE=true`) — **back up `/config` before a version bump**.

## Local development

```bash
cp .env.example .env
docker compose up -d --build
docker compose logs -f
```

Full start-up test (the one CI runs):

```bash
./test/smoke.sh local/buzz-aio:latest
```

## Troubleshooting

### Normal start-up messages

Three harmless messages show up on every start. The relay is up if the logs end with `buzz-relay TCP listening`.

**`ERROR: partition "events_p2026_07" would overlap partition "events_p_future"`** (Postgres). The relay tries to create its monthly partitions while a catch-all "future" partition already covers them. Migrations still complete (`Database migrations complete`): this is a cosmetic upstream issue, not one of this packaging.

**`WARNING Memory overcommit must be enabled`** (Redis). Redis is only a pub/sub bus and presence counter here, with a tiny dataset, so the warning has no practical effect. To silence it, run `sysctl vm.overcommit_memory=1` on the Unraid host.

**`A host failure will result in data becoming unavailable`** (MinIO). Expected on single-drive storage — that is the intended setup here, with redundancy provided by the Unraid array.

### Real problems

**The container restarts in a loop.** Check the logs: the relay waits up to 90 s for Postgres, then gives up. On a slow first start (array spinning up), a restart is usually enough.

**Clients connect but authentication fails.** `RELAY_URL` doesn't match the address actually in use. It must include the exact scheme and port.

**"relay démarre en mode OUVERT" in the logs.** `RELAY_OWNER_PUBKEY` is empty or is not 64 hex characters.

**Permission problems on `/mnt/user/appdata/buzz`.** Adjust `PUID`/`PGID`; the image applies ownership at init, but does not recursively rewrite an existing tree.

## Licence

The Buzz relay is published by Block under the Apache 2.0 licence. This repository only contains the packaging (Dockerfile, service scripts, Unraid template).
