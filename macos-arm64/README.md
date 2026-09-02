# Hermes Agent + llama.cpp — macOS Apple Silicon (ARM64)

`llama-server` tourne **en natif** sur le Mac pour profiter de l'accélération
GPU **Metal** — Docker Desktop pour Mac ne sait pas exposer le GPU Metal à un
conteneur (les conteneurs Linux qu'il fait tourner n'y ont pas accès), donc le
faire tourner en Docker ferait retomber l'inférence sur le CPU, sans intérêt.
**Hermes**, lui, n'a pas besoin de GPU (c'est juste le harnais qui appelle le
modèle en HTTP) : il tourne dans un conteneur Docker `linux/arm64`, et joint
`llama-server` via `host.docker.internal`.

```
┌─────────────────────────────── Mac (Apple Silicon) ───────────────────────────────┐
│                                                                                    │
│   llama-server (natif, Metal)          http://host.docker.internal:8080/v1        │
│   scripts/run-llama-server.sh  ◄─────────────────────────────────┐                │
│         │                                                        │                │
│         ▼                                                ┌───────┴───────┐        │
│    modèle .gguf (./models)                               │ Docker Desktop│        │
│                                                            │  ┌─────────┐  │        │
│                                                            │  │ hermes  │  │        │
│                                                            │  │(arm64)  │  │        │
│                                                            │  └────┬────┘  │        │
│                                                            └───────┼───────┘        │
│                                                                    ▼                │
│                                                        ./data (mémoire, skills)     │
└────────────────────────────────────────────────────────────────────────────────────┘
                                                                     │
                                                                     ▼
                                                              Telegram (bot)
```

## Prérequis

- Un Mac Apple Silicon (M1/M2/M3/M4...).
- [Docker Desktop pour Mac](https://www.docker.com/products/docker-desktop/) — uniquement pour le conteneur `hermes`.
- Xcode Command Line Tools + CMake, **seulement** si aucun `llama-server` n'est
  déjà disponible sur la machine (`xcode-select --install`, `brew install cmake`).
- Un bot Telegram — voir [`../shared/telegram-setup.md`](../shared/telegram-setup.md).

> Ce dépôt sait réutiliser un `llama-server` déjà compilé — voir
> [`scripts/find-or-build-llama-server.sh`](scripts/find-or-build-llama-server.sh) :
> il regarde `LLAMA_SERVER_BIN`, puis `~/Documents/Code/llama.cpp/build/bin/llama-server`,
> puis `brew install llama.cpp`, et ne clone/compile dans `./vendor` qu'en dernier recours.

## Installation

```bash
git clone https://github.com/ka8t/Hermes.git
cd Hermes/macos-arm64
cp .env.example .env
```

Éditer `.env` : au minimum `TELEGRAM_BOT_TOKEN` et `TELEGRAM_ALLOWED_USERS`
(détails dans [`../shared/telegram-setup.md`](../shared/telegram-setup.md)).

```bash
./scripts/download-model.sh          # télécharge le modèle par défaut dans ./models
mkdir -p data
cp config/config.yaml.example data/config.yaml
```

## Démarrage

**Terminal 1 — le modèle, en natif :**

```bash
./scripts/run-llama-server.sh
# ==> Binaire : /Users/xxx/Documents/Code/llama.cpp/build/bin/llama-server (ou reconstruit)
# ==> Modèle  : .../models/qwen2.5-coder-7b-instruct-q4_k_m.gguf
# ggml_metal_device_init: GPU name: Apple M... 
# server is listening on http://127.0.0.1:8080
```

Garder ce terminal ouvert (ou l'installer comme service en arrière-plan, voir
plus bas).

**Terminal 2 — Hermes, dans Docker :**

```bash
docker compose up -d
docker compose logs -f hermes
```

Puis, **une seule fois**, brancher Telegram :

```bash
docker compose exec hermes hermes gateway setup
```

## Vérification

```bash
curl http://127.0.0.1:8080/health          # llama-server
docker compose exec hermes hermes doctor   # hermes
```

Sur Telegram, envoyer un message au bot : « tu m'entends ? ». Une réponse
confirme la chaîne complète : Telegram → conteneur hermes →
`host.docker.internal:8080` → `llama-server` (Metal) → modèle → retour.

## Faire tourner `llama-server` en arrière-plan (optionnel)

Pour ne pas garder un terminal ouvert en permanence, un modèle de service
`launchd` est fourni :

```bash
cp scripts/com.hermes.llama-server.plist.example \
   ~/Library/LaunchAgents/com.hermes.llama-server.plist
# éditer les 3 occurrences de REPLACE_WITH_REPO_PATH dans ce fichier
launchctl load ~/Library/LaunchAgents/com.hermes.llama-server.plist
```

Logs : `tail -f macos-arm64/llama-server.log`. Pour l'arrêter :
`launchctl unload ~/Library/LaunchAgents/com.hermes.llama-server.plist`.

## Opérations courantes

```bash
docker compose restart hermes
docker compose exec hermes hermes doctor --fix
docker compose down                        # arrête hermes (./data et ./models persistent)
```

## Dépannage

| Symptôme | Piste |
|---|---|
| `Connection refused` depuis le conteneur hermes | `llama-server` n'est pas lancé, ou lié à une autre interface — vérifier `./scripts/run-llama-server.sh` en terminal 1 |
| Réponse très lente / tout en CPU | Vérifier que le binaire utilisé a bien été compilé avec `GGML_METAL=ON` (`grep METAL` dans son `CMakeCache.txt`, ou les logs de démarrage doivent mentionner `ggml_metal_device_init`) |
| Outils renvoyés en JSON texte au lieu de s'exécuter | Le flag `--jinja` manque au lancement de `llama-server` (déjà inclus dans `run-llama-server.sh`) |
| `docker: no matching manifest for linux/arm64` | Image `hermes-agent` obsolète en cache — `docker compose pull` |

## Sources

- Support Metal de llama.cpp : [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)
- Image et volumes Hermes (multi-arch amd64/arm64 confirmé sur Docker Hub) : [hermes-agent.nousresearch.com/docs/user-guide/docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)
- Provider `custom` / `config.yaml` : [hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
- `host.docker.internal` sur Docker Desktop Mac : [documentation Docker officielle](https://docs.docker.com/desktop/networking/)
