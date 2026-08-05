# CLAUDE.md — server-backup-gdrive

Sauvegarde quotidienne **portable** d'un serveur vers Google Drive. Le même
`backup.sh` tourne à l'identique sur `ghost` et sur le VPS OVH ; tout ce qui
change d'une machine à l'autre est dans son `.env` local. Aucun nom de machine
n'apparaît dans le script — c'est une contrainte volontaire, vérifiable :

```bash
grep -riE "ghost|vps-tlpcreation|tanguylprs|tlpdev" backup.sh   # ne doit rien sortir
```

Remplace l'ancien `infra/server-backup/` (mono-machine, qui tirait le VPS en
SSH depuis `ghost`), supprimé le 2026-08-05. Le nouveau découpage : chaque
serveur se sauvegarde lui-même, ce qui supprime la dépendance SSH et le point
unique de panne.

## Ce qu'il sauvegarde — par découverte, pas par liste

Rien n'est énuméré à la main dans le script : ce qui est trouvé sur la machine
est sauvegardé. C'est le cœur du design — un nouveau projet déployé sur un
serveur est couvert dès le lendemain, sans toucher au code.

| Source | Comment elle est découverte | Où ça atterrit |
|---|---|---|
| Bases Postgres | tout conteneur actif dont l'environnement porte `POSTGRES_DB` (toutes les images officielles et dérivées le posent) → `pg_dump` avec les identifiants lus dans le conteneur | `databases/<conteneur>.sql.gz` |
| Volumes Docker | tous les volumes **nommés**, sauf ceux de `BACKUP_EXCLUDE_VOLUMES` | `volumes/<volume>.tar.gz` |
| Code et docs | `WORKSPACE_DIR`, hors motifs de `BACKUP_EXCLUDE_PATTERNS` | `workspace/<nom>.tar.gz` + synchro incrémentale |
| Configs critiques | les chemins listés dans `BACKUP_CONFIG_PATHS` | `configs/<chemin-aplati>.tar.gz` |

Les identifiants Postgres ne sont **jamais** écrits dans le `.env` ni dans le
script : ils sont lus dans l'environnement du conteneur au moment du dump.

Les volumes anonymes (nom = 64 caractères hexadécimaux) sont ignorés : Docker
les recrée à la volée et ils ne survivent pas à un `compose down -v`. Les
volumes de **données Postgres** sont à mettre dans `BACKUP_EXCLUDE_VOLUMES` :
les `pg_dump` les couvrent déjà, et une copie brute des fichiers n'est pas
restaurable sur une autre version majeure de Postgres.

## Deux stratégies d'envoi, pour une raison de quota

Le Drive est petit (15 Go par compte gratuit). D'où deux traitements séparés :

- **Snapshots GFS datés** (`daily/<date>/`, `weekly/`, `monthly/`) pour les
  bases, volumes et configs — quelques Mo par jour. Rétention **14 / 8 / 12**,
  soit ~1 an de profondeur de restauration. Le dimanche et le 1er du mois, le
  snapshot du jour est recopié **côté serveur Drive** vers `weekly/` et
  `monthly/` : aucun octet ne remonte une deuxième fois.
- **Synchro incrémentale** vers `workspace-latest/` pour le code — un seul
  exemplaire, tenu à jour. Le tar du dossier de travail (des centaines de Mo)
  est **volontairement exclu des snapshots GFS** : multiplié par 34 snapshots,
  il saturerait le quota à lui seul. Le code n'a pas besoin d'un historique
  profond (chaque projet a son `.git`), juste d'être à jour si le serveur brûle.

Le tar du dossier de travail est quand même produit et vérifié à chaque run
(c'est lui qui prouve que le dossier est archivable), puis gardé en local dans
le staging pendant 2 jours.

## `gzip -t` est le seul juge

⚠️ Le code de retour de `tar` est **ignoré partout, exprès**. GNU tar sort en 1
ou 2 dès qu'un fichier a changé pendant la lecture (base vivante) ou a été
sauté (fichier appartenant à root), alors que l'archive produite est
parfaitement valide. S'y fier faisait jeter l'archive à chaque passage — sur
l'ancien script, `~/docker` du VPS n'a en réalité **jamais** été sauvegardé
jusqu'à ce que ce soit découvert le 2026-08-04. La validité d'une archive est
donc décidée uniquement par `gzip -t`, après écriture sous un nom `.part` et
avant renommage : jamais d'archive tronquée sous un nom définitif.

⚠️ Deuxième piège du même épisode : GNU tar n'applique `--exclude` qu'aux
opérandes qui le **suivent**. Placé après le nom du dossier, il est ignoré en
silence. D'où la construction du tableau `TAR_EXCLUDES` avant l'opérande.

## Échecs et alertes

Une étape ratée n'interrompt pas le run (une base injoignable ne doit pas
priver de sauvegarde tout le reste du serveur) : elle est enregistrée, et le
bilan part en **une seule alerte Resend** vers `ALERT_EMAIL_TO` en fin de run,
qui se termine alors en code 1. Toute erreur *inattendue* (hors des cas gérés)
coupe le run immédiatement et alerte, via un `trap ERR`.

Sans `RESEND_API_KEY` dans le `.env`, l'échec est seulement journalisé — le run
reste en erreur, donc visible dans `systemctl status`, mais **personne n'est
prévenu**. C'est le seul mode dégradé toléré.

Resend plutôt qu'un mot de passe d'application Gmail : Google déconseille ces
derniers et les restreint progressivement.

## Installation sur un nouveau serveur

```bash
git clone <remote> && cd server-backup-gdrive
cp .env.example .env && chmod 600 .env   # puis remplir
rclone listremotes                       # le remote de RCLONE_REMOTE doit exister
bash backup.sh                           # premier run à la main

sudo bash install.sh root      # ou : sudo bash install.sh ubuntu, selon la machine
```

Le dépôt est partagé entre plusieurs serveurs (`ghost`, VPS) : `install.sh`
génère l'unité systemd (`ExecStart`, `User`) à partir du chemin réel et de
l'utilisateur passé en argument, plutôt que de la commiter en dur — sinon un
`git pull` sur une machine écraserait le chemin/utilisateur de l'autre. Voir
le même principe dans `infra/server-security-audit/install.sh`.

⚠️ Toujours des **chemins absolus** dans le `.env` : quand le service tourne en
root, `~` pointe vers `/root`, pas vers le home de l'utilisateur.

## État du déploiement

| | `ghost` | VPS OVH |
|---|---|---|
| Emplacement | `~/workspace/infra/server-backup-gdrive/` | `~/workspace/infra/server-backup-gdrive/` |
| Utilisateur du service | `root` (lecture de `/etc/cloudflared`, `/etc/ufw`) | `ubuntu` (pas de sudo sans mot de passe) |
| Remote | `gdrive-tanguylprs:ghost-backups` (compte `tanguylprs@gmail.com`) | `gdrive-tlpdev:vps-backups` (compte `tlpcreation.dev@gmail.com`) |
| Timer | 3h00 UTC | 3h00 UTC |

Un compte Drive par machine : si l'un est saturé ou révoqué, l'autre continue.

Le compte `tanguylprs` est un Google One 200 Go (~100 Go libres) ; le compte
`tlpcreation.dev` est resté au palier gratuit de 15 Go. Comme un snapshot pèse
~5 Mo, les 34 snapshots de la rétention tiennent dans ~200 Mo : le quota n'est
un sujet pour aucun des deux. Ce qui pèse, c'est `workspace-latest/`
(~300 Mo pour ghost, ~600 Mo pour le VPS), et il ne grossit pas avec le temps.

### Ce qui n'est PAS couvert sur le VPS, et pourquoi

Le service y tourne en `ubuntu` (pas de sudo sans mot de passe), et plusieurs
services montent leurs données **en bind-mount dans `~/workspace/`** au lieu
d'un volume Docker — donc hors de la découverte automatique des volumes. Ces
chemins sont exclus explicitement, chacun pour une raison constatée en
conditions réelles (chacun faisait sortir `rclone` en erreur, donc produisait
une fausse alerte par nuit) :

| Chemin exclu | Raison | Conséquence |
|---|---|---|
| `infra/traefik/letsencrypt`, `infra/nginx/letsencrypt` | clés privées en root 600, illisibles | aucune — Let's Encrypt réémet les certificats au redémarrage de Traefik |
| `infra/umami/umami-db-data` | données Postgres brutes, root (uid 70) | aucune — le `pg_dump` de `umami-db` les couvre déjà |
| `infra/uptime-kuma/data` | MariaDB vivante : socket + `ib_logfile0` réécrit pendant la copie | ⚠️ **l'historique de supervision n'a aucune copie cloud** |
| `infra/beszel/beszel_data/*.db-wal`, `*.db-shm` | journaux SQLite réécrits en cours de copie | les `.db` sont copiés à chaud, donc restauration en « meilleur effort » |

La ligne uptime-kuma est le seul vrai trou. Le couvrir proprement demande une
étape de **dump** (`mysqldump` dans le conteneur) plutôt qu'une copie de
fichiers — c'est-à-dire le même traitement que Postgres, mais pour MariaDB.
À décider séparément : ce n'est pas un cas générique que l'auto-discovery
actuelle sait traiter.

L'unité installée sur `ghost` porte en plus `OnSuccess=reboot-if-needed.service`
(héritée de l'ancien `server-backup.service`, qui en était le seul déclencheur).

⚠️ Avertissement rclone à chaque run : *« This remote uses rclone's shared
Google Drive client_id, which is being retired... during 2026 »*. Pas bloquant
aujourd'hui, mais il faudra créer un client_id Google Cloud dédié avant que ça
casse.

## Restaurer

1. **Configs** : extraire chaque `configs/*.tar.gz` à l'emplacement d'origine
   (le nom de l'archive est le chemin, `/` remplacés par `-`), puis
   `systemctl daemon-reload` / `ufw reload` selon le cas.
2. **Code** : extraire `workspace/<nom>.tar.gz` dans le home (ou récupérer
   `workspace-latest/` pour la version à jour) — redonne tous les
   `docker-compose.yml` pour relancer chaque service.
3. **Volumes** : `docker volume create <nom>` puis
   `docker run --rm -v <nom>:/data -v $(pwd):/backup alpine tar xzf /backup/<nom>.tar.gz -C /data`.
4. **Bases** : conteneur Postgres relancé vide, puis
   `gunzip -c databases/<conteneur>.sql.gz | docker exec -i <conteneur> psql -U <user> <db>`.

## Voisinage

- `infra/gdrive-nas-mirror/` (à construire) redescend ces sauvegardes du Drive
  vers le NAS de `ghost` — c'est lui qui assure la copie locale, plus ce script.
- `public/saltyhorizon/backup/backup_db.sh` garde son propre pipeline isolé
  (compte Drive du client), via `infra/lib/gfs.sh`. Doublon volontaire.
