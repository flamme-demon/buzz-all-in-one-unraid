# Buzz all-in-one pour Unraid

[Buzz](https://github.com/block/buzz) est un espace de travail auto-hébergé, développé par Block, où humains et agents IA collaborent dans des salons partagés : messages, revues de code, étapes de workflow et évènements git sont tous des évènements Nostr signés, dans un journal d'audit unique.

Le relay Buzz est un binaire Rust qui a besoin de trois services externes :

| Service | Rôle |
| --- | --- |
| PostgreSQL 17 | stockage des évènements et recherche plein texte |
| Redis 7 | pub/sub et présence |
| S3 (MinIO) | stockage des médias (protocole Blossom) |

Ce dépôt les réunit dans **une seule image Docker**, supervisée par [s6-overlay](https://github.com/just-containers/s6-overlay), pour tenir dans le modèle « un conteneur = une application » d'Unraid — au lieu d'une pile de quatre conteneurs à orchestrer à la main.

Les binaires du relay ne sont pas recompilés : ils sont repris tels quels de l'image officielle `ghcr.io/block/buzz`, épinglée par digest dans [`versions.env`](versions.env).

## Installation sur Unraid

### 1. Récupérer l'image

L'image est publiée par la CI de ce dépôt :

```
ghcr.io/<votre-compte>/buuz-all-in-one-unraid:latest
```

Pour la construire vous-même, depuis un terminal Unraid :

```bash
git clone https://github.com/<votre-compte>/buuz-all-in-one-unraid.git
cd buuz-all-in-one-unraid
./build.sh
```

### 2. Ajouter le conteneur

Copiez [`unraid/buzz-aio.xml`](unraid/buzz-aio.xml) dans `/boot/config/plugins/dockerMan/templates-user/`, puis, dans l'onglet **Docker** d'Unraid, *Add Container* → sélectionnez `buzz-aio` dans la liste des templates utilisateur.

À défaut, créez le conteneur à la main avec les réglages du tableau ci-dessous.

### 3. Régler les deux variables qui comptent

**`RELAY_URL`** — l'adresse à laquelle vos clients joignent réellement le relay, par exemple `ws://192.168.1.10:3000`, ou `wss://buzz.mondomaine.tld` derrière un reverse proxy. Elle sert aux défis d'authentification NIP-42 : si elle ne correspond pas, les clients se connectent puis échouent à s'authentifier, ce qui donne un symptôme déroutant (« connecté » mais rien ne marche).

**`RELAY_OWNER_PUBKEY`** — votre clé publique Nostr, en hexadécimal minuscule de 64 caractères (pas un `npub1…`). Elle active la restriction d'accès aux membres du relay. Récupérez-la dans le client Buzz après avoir créé votre identité.

> Tant que `RELAY_OWNER_PUBKEY` est vide, le relay démarre en **mode ouvert** : n'importe qui pouvant l'atteindre peut y écrire. C'est un compromis délibéré — activer la restriction sans connaître la clé de l'opérateur fermerait le relay à tout le monde, y compris à vous. Le conteneur le signale dans ses journaux à chaque démarrage. N'exposez pas le conteneur hors du réseau local dans cet état.

### 4. Démarrer

Le premier démarrage initialise le cluster Postgres, génère les secrets et applique les migrations : comptez une à deux minutes. Ensuite, l'interface web répond sur `http://<ip-unraid>:3000/`, et les clients desktop Buzz se connectent sur la même adresse.

## Réglages

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `RELAY_URL` | `ws://localhost:3000` | adresse publique du relay (NIP-42) |
| `RELAY_OWNER_PUBKEY` | *(vide)* | clé publique de l'opérateur, 64 hex |
| `PUID` / `PGID` | `99` / `100` | propriétaire des fichiers de `/config` |
| `TZ` | `Europe/Paris` | fuseau horaire |
| `BUZZ_REQUIRE_AUTH_TOKEN` | `true` | authentification exigée sur l'API REST |
| `BUZZ_REQUIRE_MEDIA_GET_AUTH` | `true` | authentification exigée en lecture des médias |
| `BUZZ_CORS_ORIGINS` | *(vide)* | origines navigateur autorisées, séparées par des virgules |
| `RUST_LOG` | `buzz_relay=info,…` | verbosité des journaux |

Toute variable reconnue par le relay (voir le [`.env.example` amont](https://github.com/block/buzz/blob/main/.env.example)) peut être ajoutée au conteneur : elle est transmise telle quelle. Seules `DATABASE_URL`, `REDIS_URL` et les variables `BUZZ_S3_*` sont imposées par l'image, puisqu'elles pointent vers les services embarqués.

### Ports

| Port | Usage |
| --- | --- |
| 3000 | interface web, API REST, WebSocket — **le seul à publier** |
| 9000 | API S3 de MinIO, optionnelle : le relay sert `/media` lui-même |
| 8080 | sondes `/_liveness` et `/_readiness`, internes au conteneur |
| 9102 | métriques Prometheus, internes au conteneur |

Pour exposer les métriques, publiez le port 9102 dans le template.

## Données et sauvegarde

Tout vit sous `/config` (par défaut `/mnt/user/appdata/buzz`) :

```
/config
├── secrets.env    identité Nostr du relay + mots de passe internes
├── postgres/      base de données
├── minio/         médias
├── git/           dépôts NIP-34
├── git-packs/     cache de packs git (reconstructible)
└── redis/         snapshot pub/sub (reconstructible)
```

`secrets.env` est généré au premier démarrage et contient `BUZZ_RELAY_PRIVATE_KEY`, **l'identité Nostr du relay**. La perdre revient à changer l'identité du relay aux yeux de tous les clients : sauvegardez ce fichier, et si vous restaurez, restaurez-le avec le reste de `/config`.

## Mises à jour

`versions.env` est la source de vérité de tout ce qui est embarqué. Le workflow [`watch-upstream.yml`](.github/workflows/watch-upstream.yml) le vérifie chaque jour et met à jour, le cas échéant :

- le digest de `ghcr.io/block/buzz:latest` (le relay lui-même) ;
- s6-overlay, MinIO et le client `mc`.

Un changement est commité sur `main`, ce qui relance [`build.yml`](.github/workflows/build.yml). Celui-ci **démarre l'image et attend que `/_readiness` passe au vert avant de publier** : une version amont qui ne démarre pas avec cette pile bloque la publication au lieu de casser les installations. Une reconstruction hebdomadaire récupère par ailleurs les correctifs de sécurité Debian.

Postgres reste épinglé sur la 17 : un changement de version majeure imposerait une migration du cluster existant, qui doit rester une décision manuelle.

Côté Unraid, la mise à jour est le bouton habituel du conteneur. Les migrations de schéma sont appliquées automatiquement au démarrage (`BUZZ_AUTO_MIGRATE=true`) — **sauvegardez `/config` avant une montée de version**.

## Développement local

```bash
cp .env.example .env
docker compose up -d --build
docker compose logs -f
```

Test de démarrage complet (celui que la CI exécute) :

```bash
./test/smoke.sh local/buzz-aio:latest
```

## Dépannage

**Le conteneur redémarre en boucle.** Regardez les journaux : le relay attend jusqu'à 90 s que Postgres soit prêt, puis abandonne. Sur un premier démarrage lent (array en spin-up), un simple redémarrage suffit généralement.

**Les clients se connectent mais l'authentification échoue.** `RELAY_URL` ne correspond pas à l'adresse réellement utilisée. Elle doit inclure le schéma et le port exacts.

**« relay démarre en mode OUVERT » dans les journaux.** `RELAY_OWNER_PUBKEY` est vide ou n'est pas au format hexadécimal 64 caractères.

**Droits d'accès sur `/mnt/user/appdata/buzz`.** Ajustez `PUID`/`PGID` ; l'image applique la propriété à l'initialisation, mais ne réécrit pas récursivement une arborescence existante.

## Licence

Le relay Buzz est publié par Block sous licence Apache 2.0. Ce dépôt ne contient que l'empaquetage (Dockerfile, scripts de service, template Unraid).
