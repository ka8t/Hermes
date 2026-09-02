# Hermes

Déploiement de [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(l'agent IA open source auto-hébergé de Nous Research) branché sur un LLM
**local** servi par [llama.cpp](https://github.com/ggml-org/llama.cpp) —
aucune clé API externe, aucune donnée envoyée à un service tiers, tout tourne
sur du matériel qu'on possède ou qu'on loue.

Deux configurations complètes, indépendantes l'une de l'autre :

| Configuration | Où | llama.cpp | Hermes | Guide |
|---|---|---|---|---|
| **macOS ARM64** | Un Mac Apple Silicon | natif (accélération Metal) | Docker (`linux/arm64`) | [`macos-arm64/`](macos-arm64/) |
| **Linux x86-64** | Un VPS loué | Docker (CPU) | Docker (`linux/amd64`) | [`linux-x86_64-vps/`](linux-x86_64-vps/) |

Les deux branchent Hermes sur Telegram (voir
[`shared/telegram-setup.md`](shared/telegram-setup.md)) et servent par défaut
le même modèle, **Qwen2.5-Coder-7B-Instruct** en `Q4_K_M` (voir
[`shared/model-notes.md`](shared/model-notes.md) pour en changer).

## Pourquoi llama.cpp en natif sur Mac mais en Docker sur le VPS ?

Docker Desktop pour Mac ne peut pas exposer le GPU Metal à un conteneur —
y faire tourner `llama-server` le condamnerait au CPU. Sur un Mac, on le lance
donc en natif (accès Metal complet), et seul Hermes — qui n'a besoin que
d'appeler une API HTTP, pas de GPU — tourne en Docker. Sur un VPS Linux
classique (sans GPU dédié), cette distinction n'a pas lieu d'être : tout tient
proprement dans `docker-compose.yml`, llama.cpp compris.

## Pourquoi ce modèle par défaut ?

Hermes exige au moins 64 000 tokens de contexte pour fonctionner (mémoire +
outils + historique à chaque appel), et les appels d'outils ne s'exécutent
qu'avec le flag `--jinja` de llama.cpp — les deux points, faciles à manquer,
sont expliqués et déjà réglés dans les deux configurations. Voir
[`shared/model-notes.md`](shared/model-notes.md).

## Démarrage rapide

```bash
git clone https://github.com/ka8t/Hermes.git
cd Hermes

# Sur un Mac Apple Silicon
cd macos-arm64 && cat README.md

# Sur un VPS Linux x86-64
cd linux-x86_64-vps && cat README.md
```

## Structure du dépôt

```
Hermes/
├── macos-arm64/          # llama.cpp natif (Metal) + Hermes en Docker
├── linux-x86_64-vps/     # llama.cpp + Hermes, tous deux en Docker Compose
└── shared/
    ├── telegram-setup.md # création du bot, variables d'environnement
    └── model-notes.md    # choix du modèle GGUF, contraintes de contexte
```

## Sécurité

Aucun secret n'est commité : `.env` est ignoré par git (seuls les
`.env.example` le sont), de même que les modèles `.gguf` (trop volumineux) et
l'état persistant d'Hermes (`data/`, mémoire et sessions comprises). Voir
`.gitignore`.

## Sources

- Hermes Agent — dépôt officiel : https://github.com/NousResearch/hermes-agent
- Documentation officielle : https://hermes-agent.nousresearch.com/docs/
- llama.cpp — dépôt officiel : https://github.com/ggml-org/llama.cpp
