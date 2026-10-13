# qbittorrent-notify

Notifications **Pushbullet** et **Telegram** (avec affiche IMDb) a la fin d'un telechargement qBittorrent, pensees pour une **seedbox** (aucun droit root requis).

Le script ne recoit que le **hash** du torrent (`%I`). Toutes les autres informations (nom, categorie, ratio, taille, dates, tracker, seeds/peers, etc.) sont lues via la **WebAPI de qBittorrent**. Cela evite les decalages d'arguments et les placeholders non remplaces (ex. `%J`).

## Fichiers

| Fichier | Role |
|---|---|
| `pushbullet.sh` | Script principal : envoie la notif Pushbullet puis lance `telegram.sh` |
| `telegram.sh` | Notif Telegram avec affiche IMDb (via OMDb), optionnel |
| `pushbullet.conf` | Tokens et identifiants (a remplir, ne jamais publier) |

## Compatibilite qBittorrent

- WebAPI v2 : qBittorrent **4.1 et plus** (endpoints `torrents/info`, `torrents/properties`, `torrents/files`).
- Fonctionne avec `qbittorrent-nox` et l'interface graphique, sous Linux.
- Version 5.x : les endpoints utilises existent toujours. Certains etats peuvent differer (`stoppedUP` au lieu de `pausedUP`).
- Verifie ta version apres login :
  ```bash
  curl --noproxy '*' -s -b /tmp/qb.cookie http://127.0.0.1:PORT/api/v2/app/version
  ```

## 1. Installation

Aucune installation de paquet n'est necessaire : sur une seedbox, `curl`, `jq` et `coreutils` sont generalement deja presents. Verification rapide (optionnelle) :

```bash
command -v curl jq numfmt
```

Si `numfmt` est absent, les tailles s'affichent en octets. Si `jq` ou `curl` manquent, contacte le support de ta seedbox.

Recupere les fichiers (via `git clone` ou en les copiant par SFTP) :

```bash
mkdir -p ~/scripts
cd ~/scripts
git clone https://github.com/franck51000/qbittorrent-notify.git
cd qbittorrent-notify
chmod 700 pushbullet.sh telegram.sh
chmod 600 pushbullet.conf
nano pushbullet.conf
```

Le script lit `pushbullet.conf` dans **son propre dossier**. Aucun chemin n'est code en dur.

## 2. Configuration de qBittorrent

**Options > Web UI** :

- Activer l'interface Web.
- Noter l'adresse IP (ex. `127.0.0.1`) et le **port**.
- Definir un nom d'utilisateur et un mot de passe.
- Renseigner les memes valeurs dans `pushbullet.conf` (`QB_URL`, `QB_USER`, `QB_PASS`).

Sur une seedbox, le port de la WebUI est souvent personnalise : utilise celui affiche dans les options.

## 3. Commande dans qBittorrent

**Options > Downloads > Run external program > Run on torrent finished** :

```text
/chemin/complet/vers/pushbullet.sh "%I"
```

Exemple : `/home/TON_UTILISATEUR/scripts/qbittorrent-notify/pushbullet.sh "%I"`

Utilise **un seul** argument (`%I`), sans `;` ni `&&` : qBittorrent n'execute pas toujours la commande dans un vrai shell.

## 4. Tester

Remplace `HASH` par le hash d'un torrent existant :

```bash
./pushbullet.sh "HASH"
tail -n 20 pushbullet.log telegram.log
```

Tests de la WebAPI :

```bash
curl --noproxy '*' -si http://127.0.0.1:PORT/api/v2/app/version        # 403 = bon port, non authentifie
curl --noproxy '*' -sS -c /tmp/qb.cookie --data-urlencode "username=TON_UTILISATEUR_QBIT" --data-urlencode "password=TON_MDP" http://127.0.0.1:PORT/api/v2/auth/login   # Ok.
curl --noproxy '*' -sS -b /tmp/qb.cookie "http://127.0.0.1:PORT/api/v2/torrents/properties?hash=HASH" | jq
```

## 5. Configuration Telegram (optionnel)

1. Cree un bot avec `@BotFather` (`/newbot`) pour obtenir `TG_TOKEN`.
2. Envoie un message au bot, puis ouvre `https://api.telegram.org/bot<TOKEN>/getUpdates` pour lire `chat.id` (`TG_CHAT_ID`).
3. Cle gratuite OMDb : https://www.omdbapi.com/apikey.aspx (`OMDB_KEY`).
4. Sans `OMDB_KEY`, le message part sans affiche.
5. Sans `TG_TOKEN`/`TG_CHAT_ID`, `telegram.sh` s'arrete et l'erreur est ecrite dans `telegram.log`.

Limites : OMDb cherche par titre exact (pas ideal pour les titres francais). Pour une serie, c'est l'affiche de la serie, pas de la saison.

## Depannage

| Symptome | Cause probable | Solution |
|---|---|---|
| `jq: parse error` | Une page HTML (proxy Squid, etc.) repond a la place de qBittorrent | Verifier le port, utiliser `--noproxy '*'` |
| `403 Forbidden` | Non authentifie | Faire le login, ou activer le bypass localhost |
| `Fails.` au login | Mauvais identifiants | Verifier `QB_USER` / `QB_PASS` |
| IP bannie | Trop d'echecs de login | Attendre la fin du ban ou redemarrer qBittorrent |
| `%J` ou valeurs decalees dans la notif | Ancienne commande avec plusieurs variables | Utiliser uniquement `"%I"` |
| `État: checkingDL` | Notif envoyee pendant la verification | Utiliser l'option *a la fin du telechargement* |
| Rien ne se lance | Droits, CRLF | `chmod 700 *.sh`, `sed -i 's/\r$//' *.sh` |

## Securite

- Ne publie jamais `pushbullet.conf` rempli. Garde le depot **prive**.
- Le domaine du tracker est affiche, jamais l'URL complete (elle contient la passkey).
- Droits conseilles : `chmod 700` sur les scripts, `chmod 600` sur `pushbullet.conf`.

## Logs

- `pushbullet.log` : resultats Pushbullet et erreurs de login qBittorrent.
- `telegram.log` : resultats Telegram et OMDb.
