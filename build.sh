#!/usr/bin/env bash
# Construit l'image all-in-one avec les versions figées dans versions.env.
#
#   ./build.sh                                   # versions.env tel quel
#   BUZZ_REF=ghcr.io/block/buzz:sha-2d26db6 ./build.sh   # relay différent
#
# Pour construire directement sur le serveur Unraid, copiez ce dossier dans
# /mnt/user/appdata puis lancez le script depuis un terminal Unraid.
set -euo pipefail

cd "$(dirname "$0")"

# Les variables déjà présentes dans l'environnement l'emportent, pour permettre
# un build ponctuel sans modifier le fichier.
set -a
# shellcheck disable=SC1091
source ./versions.env
set +a

IMAGE="${IMAGE:-local/buzz-aio}"

docker build \
    --build-arg "BUZZ_REF=${BUZZ_REF}" \
    --build-arg "S6_OVERLAY_VERSION=${S6_OVERLAY_VERSION}" \
    --build-arg "MINIO_VERSION=${MINIO_VERSION}" \
    --build-arg "MC_VERSION=${MC_VERSION}" \
    --build-arg "PG_MAJOR=${PG_MAJOR}" \
    --tag "${IMAGE}:latest" \
    --tag "${IMAGE}:${BUZZ_TAG}" \
    "$@" \
    .

printf '\nImage construite : %s:latest\n  relay    %s\n' "${IMAGE}" "${BUZZ_REF}"
