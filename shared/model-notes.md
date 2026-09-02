# Choisir un modèle GGUF pour llama.cpp

## Contrainte non négociable : le contexte

Hermes a besoin d'au moins **64 000 tokens** de fenêtre de contexte pour
fonctionner correctement (mémoire, liste d'outils et historique sont renvoyés
à chaque appel). En dessous, Hermes refuse de démarrer ou dégrade fortement.
Les deux configurations de ce dépôt lancent donc `llama-server` avec `-c 65536`
(ou l'équivalent dans `LLAMA_CTX_SIZE`).

## Le flag qui fait fonctionner les outils : `--jinja`

Sans `--jinja`, `llama-server` ignore le paramètre `tools` envoyé par Hermes :
les appels d'outils ressortent comme du texte JSON brut dans la réponse au
lieu de s'exécuter. C'est la cause n°1 d'un agent qui « répond du JSON »
plutôt que d'agir. Les deux `docker-compose.yml` / scripts de ce dépôt
incluent déjà `--jinja`.

## Modèle par défaut retenu ici

**Qwen2.5-Coder-7B-Instruct** (quantification `Q4_K_M`, ~4,7 Go) — bon
compromis taille/qualité pour un usage agentique, tourne correctement sur un
VPS 8 Go de RAM en CPU, et profite du GPU Metal sur un Mac Apple Silicon.

- Dépôt officiel (GGUF) : https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF
- Fichier utilisé par les scripts : `qwen2.5-coder-7b-instruct-q4_k_m.gguf`

> Si Hugging Face a renommé le fichier depuis, ouvrez la page ci-dessus et
> ajustez `MODEL_FILE` dans `.env` en conséquence — les scripts ne fabriquent
> pas d'autre nom que celui-ci.

## Aller plus loin

| Modèle | Quand le préférer |
|---|---|
| Qwen2.5-Coder-7B-Instruct (défaut) | Premier essai, VPS modeste, Mac 16 Go |
| Qwen2.5-Coder-32B-Instruct | Mac Apple Silicon 32 Go+ (bien plus capable) |
| Hermes-3-Llama-3.1-8B (Nous Research) | Modèle « maison », bon rapport perf/taille |
| Llama-3.1-70B-Instruct | GPU dédié costaud uniquement (vLLM/SGLang, pas ce dépôt) |

Source : documentation officielle des fournisseurs Hermes —
[hermes-agent.nousresearch.com/docs/integrations/providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)
et fiche modèle Qwen sur Hugging Face.
