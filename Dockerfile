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

# MinIO (serveur S3) et mc (client, utilisé pour créer le bucket au premier
# démarrage). Les deux projets open source de MinIO sont archivés et dl.min.io
# ne sert plus aucun binaire : les binaires sont donc copiés depuis leurs
# images officielles quay.io, épinglées par digest — ce sont exactement les
# références du profil quickstart du chart Helm officiel de Buzz. Contrairement
# aux hotfixs, ces images restent multi-arch (arm64 compris), pour un build
# local hors CI.
ARG MINIO_IMAGE=quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e
ARG MC_IMAGE=quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727

FROM ${BUZZ_REF} AS buzz-upstream
FROM ${MINIO_IMAGE} AS minio-upstream
FROM ${MC_IMAGE} AS mc-upstream

# ─── Runtime ────────────────────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}-slim

ARG S6_OVERLAY_VERSION=3.2.3.2
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

# Binaires MinIO + mc, copiés depuis leurs images officielles (voir les ARG en
# tête de fichier) : plus rien n'est téléchargé, dl.min.io ne servant plus
# aucun binaire depuis l'archivage des projets.
COPY --from=minio-upstream /usr/bin/minio /usr/local/bin/minio
COPY --from=mc-upstream /usr/bin/mc /usr/local/bin/mc
RUN chmod 0755 /usr/local/bin/minio /usr/local/bin/mc

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
