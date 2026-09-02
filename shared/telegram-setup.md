# Connexion Telegram

Commune aux deux configurations (macOS et VPS Linux) : Hermes ne parle à Telegram
qu'une fois un bot créé et ses identifiants renseignés dans `.env`.

## 1. Créer le bot avec @BotFather

1. Ouvrir Telegram, chercher **@BotFather**, envoyer `/newbot`.
2. Donner un nom d'affichage, puis un nom d'utilisateur se terminant par `bot`
   (ex. `mon-hermes-bot`).
3. BotFather répond avec un token du type :
   `123456789:ABCdefGHIjklMNOpqrSTUvwxYZ`
   → c'est la valeur de `TELEGRAM_BOT_TOKEN`.

## 2. Récupérer son identifiant Telegram

1. Chercher **@userinfobot** sur Telegram, lui envoyer n'importe quel message.
2. Il répond avec un `Id` numérique → c'est la valeur de `TELEGRAM_ALLOWED_USERS`.
3. Sans cette liste blanche, n'importe qui qui trouve le bot peut lui écrire.

## 3. Renseigner `.env`

```bash
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrSTUvwxYZ
TELEGRAM_ALLOWED_USERS=123456789
```

Variables optionnelles utiles (voir la doc officielle) :

```bash
# Canal où Hermes livre les résultats des cron jobs et messages proactifs
TELEGRAM_HOME_CHANNEL=-1001234567890
TELEGRAM_HOME_CHANNEL_NAME="Mon agent"

# Pour un groupe plutôt qu'une conversation privée
TELEGRAM_GROUP_ALLOWED_USERS=987654321
TELEGRAM_GROUP_ALLOWED_CHATS=-1001234567890
```

## 4. Activer le canal côté Hermes

Une fois le conteneur démarré (voir le README de chaque plateforme), lancer
l'assistant interactif une seule fois :

```bash
docker compose exec hermes hermes gateway setup
# -> choisir "Telegram"
# -> confirmer que le token est bien lu depuis .env
```

Ou, si l'agent tourne déjà et que `.env` contient les bonnes valeurs, un simple
redémarrage de la passerelle suffit :

```bash
docker compose exec hermes hermes gateway restart
docker compose exec hermes hermes gateway status
```

## 5. Vérifier

1. Ouvrir la conversation avec le bot sur Telegram, taper `/start` (ouvre juste
   la conversation, ce n'est pas une vraie commande) puis envoyer un message,
   par exemple « tu m'entends ? ».
2. Si Hermes répond « Aucun canal principal n'est défini pour Telegram »,
   envoyer la commande `/set home` pour que ce canal reçoive aussi les
   notifications proactives (cron, tâches de fond).

Source : documentation officielle Hermes Agent —
[hermes-agent.nousresearch.com/docs/user-guide/messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
(variables d'environnement Telegram détaillées dans le fichier
[`telegram.md`](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/messaging/telegram.md)
du dépôt officiel).
