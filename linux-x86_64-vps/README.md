# Hermes Agent + llama.cpp — VPS Linux x86-64 (Docker)

Stack 100 % Docker Compose, pensée pour un petit VPS Ubuntu (type Hostinger
KVM2, 2 vCPU / 8 Go RAM) : un conteneur `llama-server` sert un modèle GGUF en
local, un conteneur `hermes` fait tourner l'agent et s'y connecte en interne —
aucune clé API externe, rien ne sort du serveur sauf les messages Telegram.

```
┌─────────────────────────── VPS (docker compose) ───────────────────────────┐
│                                                                             │
│   ┌───────────────────┐   http://llama-server:8080/v1   ┌───────────────┐  │
│   │   llama-server     │ ◄────────────────────────────── │    hermes     │  │
│   │ ghcr.io/ggml-org/  │        (réseau interne)          │ nousresearch/ │  │
│   │  llama.cpp:server  │                                  │ hermes-agent  │  │
│   └─────────┬──────────┘                                  └───────┬───────┘  │
│             │ ./models (lecture seule)                            │          │
│             ▼                                                     ▼          │
│        modèle .gguf                                     ./data (mémoire,    │
│                                                            skills, config)   │
└─────────────────────────────────────────────────────────────────────────────┘
                                                                     │
                                                                     ▼
                                                              Telegram (bot)
```

## Prérequis

- Un VPS Ubuntu 22.04+ (x86-64), au moins 8 Go de RAM pour un modèle 7B en `Q4_K_M`.
- Un accès root/sudo en SSH.
- Un bot Telegram — voir [`../shared/telegram-setup.md`](../shared/telegram-setup.md).

## Installation

```bash
ssh root@<ip-du-vps>
git clone https://github.com/ka8t/Hermes.git
cd Hermes/linux-x86_64-vps
./provision.sh
```

`provision.sh` installe Docker + le plugin Compose s'ils manquent, crée les
dossiers persistants (`data/`, `models/`), copie `.env.example` → `.env` et
`config/config.yaml.example` → `data/config.yaml`, puis télécharge le modèle
par défaut (voir [`../shared/model-notes.md`](../shared/model-notes.md) pour
en changer).

## Configuration

1. **Éditer `.env`** — au minimum `TELEGRAM_BOT_TOKEN` et
   `TELEGRAM_ALLOWED_USERS` (détails dans
   [`../shared/telegram-setup.md`](../shared/telegram-setup.md)).
2. **`data/config.yaml`** est déjà prêt (copié depuis
   `config/config.yaml.example`) : il pointe Hermes vers
   `http://llama-server:8080/v1`, le nom du service voisin dans
   `docker-compose.yml` — Docker Compose résout ce nom automatiquement, aucune
   IP à gérer.

## Démarrage

```bash
docker compose up -d
docker compose logs -f llama-server
# attendre la ligne "server is listening on http://0.0.0.0:8080"
```

Puis, **une seule fois**, brancher Telegram :

```bash
docker compose exec hermes hermes gateway setup
```

## Vérification

```bash
# santé de llama.cpp
curl http://127.0.0.1:8080/health

# état de l'agent
docker compose exec hermes hermes doctor

# logs de l'agent
docker compose logs -f hermes
```

Puis, sur Telegram, envoyer un message au bot : « tu m'entends ? ». Une
réponse confirme que la chaîne complète fonctionne (Telegram → hermes →
llama-server → modèle → retour).

Le tableau de bord web est accessible sur `http://<ip-du-vps>:9119` si
`HERMES_DASHBOARD=1` (défini par défaut dans `.env.example`) —
pensez à le protéger derrière un pare-feu ou un tunnel SSH, il n'a pas
d'authentification propre par défaut.

## Opérations courantes

```bash
docker compose restart hermes        # relance juste l'agent
docker compose exec hermes hermes doctor --fix
docker compose logs --tail 100 llama-server
docker compose down                  # arrêt (les données persistent dans ./data et ./models)
docker compose pull && docker compose up -d   # mise à jour des images
```

## Dépannage

| Symptôme | Piste |
|---|---|
| `hermes` reste en `starting` | `llama-server` n'a pas encore fini de charger le modèle — regarder `docker compose logs llama-server` |
| Les outils ressortent en texte JSON brut au lieu de s'exécuter | Le flag `--jinja` manque dans `docker-compose.yml` (déjà présent ici — à vérifier si modifié) |
| Réponses tronquées / lentes | `LLAMA_CTX_SIZE` ou `LLAMA_THREADS` mal dimensionnés pour le VPS loué — ajuster dans `.env` |
| Le bot Telegram ne répond jamais | `TELEGRAM_ALLOWED_USERS` ne correspond pas à votre identifiant réel — revoir [`../shared/telegram-setup.md`](../shared/telegram-setup.md) |

## Sources

- Image et flags llama.cpp : [ggml-org/llama.cpp — docs/docker.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md)
- Image et volumes Hermes : [hermes-agent.nousresearch.com/docs/user-guide/docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- Provider `custom` / `config.yaml` : [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- Variables Telegram : [hermes-agent.nousresearch.com/docs/user-guide/messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
