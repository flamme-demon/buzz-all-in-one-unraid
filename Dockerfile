# syntax=docker/dockerfile:1.7
#
# Buzz all-in-one — image unique pour Unraid.
#
# Le relay Buzz officiel (ghcr.io/block/buzz) est un binaire Rust qui a besoin
# de trois services externes : Postgres (stockage des events + recherche),
# Redis (pub/sub + présence) et un stockage S3 (médias, protocole Blossom).
# Cette image embarque les quatre dans un seul conteneur, supervisés par
# s6-overlay, pour tenir dans le modèle « un conteneur = une app » d'Unraid.
#
# Les binaires du relay ne sont pas recompilés : ils sont copiés depuis l'image
# officielle multi-arch, ce qui garantit qu'on livre exactement les artefacts
# publiés par Block et évite un build Rust de 30+ minutes.
#
# Les versions embarquées sont pilotées par versions.env (que build.sh lit et
# que la CI met à jour) ; les valeurs ci-dessous ne servent qu'à un
# `docker build .` lancé sans arguments.
#
# Build :
#   ./build.sh
#   docker build --build-arg BUZZ_REF=ghcr.io/block/buzz:sha-2d26db6 -t buzz-aio .

ARG BUZZ_REF=ghcr.io/block/buzz:latest
# Debian 13 (trixie) fournit Postgres 17 et Redis 8 dans ses dépôts standards :
# aucun dépôt tiers à ajouter. Les binaires du relay sont compilés sur bookworm,
# donc contre une glibc plus ancienne — ils tournent sans souci ici.
ARG DEBIAN_VERSION=trixie

FROM ${BUZZ_REF} AS buzz-upstream

# ─── Runtime ────────────────────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}-slim

ARG S6_OVERLAY_VERSION=3.2.3.2
ARG MINIO_VERSION=RELEASE.2025-09-07T16-13-09Z
ARG MC_VERSION=RELEASE.2025-08-13T08-35-41Z
ARG PG_MAJOR=17

# image.source doit désigner CE dépôt : c'est lui que GHCR lie au package et
# dont il reprend la visibilité. Le projet empaqueté est signalé à part.
LABEL org.opencontainers.image.title="Buzz all-in-one" \
      org.opencontainers.image.description="Relay Buzz + Postgres + Redis + MinIO dans un seul conteneur, pour Unraid" \
      org.opencontainers.image.source="https://github.com/flamme-demon/buzz-all-in-one-unraid" \
      org.opencontainers.image.url="https://github.com/block/buzz" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV DEBIAN_FRONTEND=noninteractive \
    PG_MAJOR=${PG_MAJOR} \
    PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}" \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KEEP_ENV=1 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0

# Postgres et Redis, plus git (le relay shelle vers git pour upload-pack /
# receive-pack) et les outils utilisés par les scripts de service.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils procps tzdata \
        git openssl redis-server postgresql-${PG_MAJOR}; \
    rm -rf /var/lib/apt/lists/*

# s6-overlay : superviseur du conteneur (ordre de démarrage, redémarrage des
# services, arrêt propre à la réception de SIGTERM).
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) S6_ARCH=x86_64 ;; \
        arm64) S6_ARCH=aarch64 ;; \
        *) echo "architecture non supportée: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 -O "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 -O "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz"; \
    tar -C / -Jxpf "s6-overlay-noarch.tar.xz"; \
    tar -C / -Jxpf "s6-overlay-${S6_ARCH}.tar.xz"; \
    rm -f /tmp/s6-overlay-*.tar.xz

# MinIO (serveur S3) + mc (client, utilisé pour créer le bucket au 1er
# démarrage). Versions épinglées sur celles que le chart Helm officiel de Buzz
# utilise pour son profil quickstart.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) MINIO_ARCH=amd64 ;; \
        arm64) MINIO_ARCH=arm64 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 -o /usr/local/bin/minio \
        "https://dl.min.io/server/minio/release/linux-${MINIO_ARCH}/archive/minio.${MINIO_VERSION}"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 -o /usr/local/bin/mc \
        "https://dl.min.io/client/mc/release/linux-${MINIO_ARCH}/archive/mc.${MC_VERSION}"; \
    chmod 0755 /usr/local/bin/minio /usr/local/bin/mc

# Binaires + bundles web de l'image officielle Buzz. Les répertoires sont copiés
# en entier plutôt que fichier par fichier : leur contenu varie selon la version
# (buzz-pair-relay et le bundle admin n'existent pas dans toutes les builds
# publiées), et une copie nominative casserait le build sur les tags anciens.
COPY --from=buzz-upstream /usr/local/bin/ /usr/local/bin/
COPY --from=buzz-upstream /srv/buzz/      /srv/buzz/

ENV BUZZ_WEB_DIR=/srv/buzz/web

COPY root/ /

RUN chmod -R 0755 /etc/s6-overlay/s6-rc.d /usr/local/bin/buzz-aio-*

# 3000 : application (WebSocket + REST + UI web)
# 9000 : API S3 MinIO (utile seulement pour un accès direct au stockage)
EXPOSE 3000 9000

VOLUME ["/config"]

ENTRYPOINT ["/init"]
