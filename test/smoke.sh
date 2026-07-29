#!/usr/bin/env bash
# Vérifie qu'une image all-in-one démarre vraiment : les quatre services
# doivent monter, le relay doit appliquer ses migrations, passer /_readiness
# (qui n'est au vert qu'avec Postgres, Redis et S3 joignables) et servir l'UI.
#
#   ./test/smoke.sh [image]
set -euo pipefail

IMAGE="${1:-local/buzz-aio:latest}"
NAME="buzz-aio-smoke-$$"
PORT="${SMOKE_PORT:-38000}"
TIMEOUT="${SMOKE_TIMEOUT:-240}"

cleanup() {
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        echo "--- journaux du conteneur ---" >&2
        docker logs "${NAME}" 2>&1 | tail -80 >&2
    fi
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    return ${rc}
}
trap cleanup EXIT

echo "Démarrage de ${IMAGE}"
docker run -d --name "${NAME}" \
    -p "${PORT}:3000" \
    -e "RELAY_URL=ws://localhost:${PORT}" \
    -e "PUID=$(id -u)" -e "PGID=$(id -g)" \
    "${IMAGE}" >/dev/null

echo -n "Attente de /_readiness "
ready=false
for _ in $(seq 1 "${TIMEOUT}"); do
    if docker exec "${NAME}" curl -fsS -o /dev/null \
            http://127.0.0.1:8080/_readiness 2>/dev/null; then
        ready=true
        break
    fi
    # Un conteneur mort ne redeviendra pas prêt : échouer tout de suite.
    if [[ "$(docker inspect -f '{{.State.Running}}' "${NAME}")" != "true" ]]; then
        echo
        echo "le conteneur s'est arrêté prématurément" >&2
        exit 1
    fi
    echo -n "."
    sleep 1
done
echo

if [[ "${ready}" != true ]]; then
    echo "le relay n'est pas devenu prêt en ${TIMEOUT}s" >&2
    exit 1
fi

# Le relay sert le bundle web sur /index.html et /assets/* ; la racine nue
# répond 404 sur les versions actuelles, d'où l'URL explicite ici et dans le
# template Unraid.
echo "Vérification de l'interface web"
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/index.html"

echo "Vérification des assets du bundle web"
asset=$(docker exec "${NAME}" sh -c \
    'grep -o "/assets/[a-zA-Z0-9._-]*\.js" /srv/buzz/web/index.html | head -1')
[[ -n "${asset}" ]] || { echo "aucun asset trouvé dans index.html" >&2; exit 1; }
curl -fsS -o /dev/null "http://127.0.0.1:${PORT}${asset}"

echo "Vérification du document NIP-11 du relay"
docker exec "${NAME}" curl -fsS -H 'Accept: application/nostr+json' \
    http://127.0.0.1:3000/ | head -c 400
echo

echo "Vérification de la persistance des secrets"
docker exec "${NAME}" test -s /config/secrets.env

echo "OK — ${IMAGE} démarre et répond."
