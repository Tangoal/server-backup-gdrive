# AGENTS.md — server-backup-gdrive

Sauvegarde quotidienne **portable** d'un serveur vers Google Drive. Le même
`backup.sh` peut tourner à l'identique sur plusieurs machines ; tout ce qui
change d'une machine à l'autre est dans son `.env` local. Aucun nom de machine
n'apparaît dans le script — c'est une contrainte volontaire, vérifiable :

```bash
grep -riE "<nom de machine>" backup.sh   # ne doit rien sortir
```

Design pensé pour un parc multi-serveurs : chaque serveur se sauvegarde
lui-même, ce qui évite toute dépendance SSH entre machines et le point unique
de panne que ça introduirait.

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

Le Drive gratuit est petit (15 Go par compte). D'où deux traitements séparés :

- **Snapshots GFS datés** (`daily/<date>/`, `weekly/`, `monthly/`) pour les
  bases, volumes et configs — quelques Mo par jour. Rétention configurable
  (`RETENTION_DAILY`/`WEEKLY`/`MONTHLY`, défaut 14/8/12, soit ~1 an de
  profondeur de restauration). Le dimanche et le 1er du mois, le snapshot du
  jour est recopié **côté serveur Drive** vers `weekly/` et `monthly/` :
  aucun octet ne remonte une deuxième fois.
- **Synchro incrémentale** vers `workspace-latest/` pour le code — un seul
  exemplaire, tenu à jour. Le tar du dossier de travail (potentiellement des
  centaines de Mo) est **volontairement exclu des snapshots GFS** : multiplié
  par le nombre de snapshots de rétention, il saturerait vite le quota. Le
  code n'a pas besoin d'un historique profond (chaque projet a son `.git`),
  juste d'être à jour si le serveur brûle.

Le tar du dossier de travail est quand même produit et vérifié à chaque run
(c'est lui qui prouve que le dossier est archivable), puis gardé en local dans
le staging pendant 2 jours.

## `gzip -t` est le seul juge

⚠️ Le code de retour de `tar` est **ignoré partout, exprès**. GNU tar sort en 1
ou 2 dès qu'un fichier a changé pendant la lecture (base vivante) ou a été
sauté (fichier appartenant à root), alors que l'archive produite est
parfaitement valide. S'y fier faisait jeter l'archive à chaque passage — sur
une version antérieure du script, un dossier entier n'a en réalité **jamais**
été sauvegardé avant que ce soit découvert par hasard. La validité d'une
archive est donc décidée uniquement par `gzip -t`, après écriture sous un nom
`.part` et avant renommage : jamais d'archive tronquée sous un nom définitif.

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
derniers et les restreint progressivement. Un compte Resend gratuit suffit
(domaine d'envoi vérifiable gratuitement, quota généreux pour un usage
d'alerting bas volume) — voir la section « Configurer les alertes email »
ci-dessous pour l'installation initiale.

## Installation sur un nouveau serveur

```bash
git clone <remote> && cd server-backup-gdrive
cp .env.example .env && chmod 600 .env   # puis remplir
rclone listremotes                       # le remote de RCLONE_REMOTE doit exister
bash backup.sh                           # premier run à la main

sudo bash install.sh root      # ou : sudo bash install.sh ubuntu, selon la machine
```

Le dépôt peut être partagé entre plusieurs serveurs : `install.sh` génère
l'unité systemd (`ExecStart`, `User`) à partir du chemin réel et de
l'utilisateur passé en argument, plutôt que de la commiter en dur — sinon un
`git pull` sur une machine écraserait le chemin/utilisateur de l'autre. Voir
le même principe dans `server-security-audit/install.sh` (projet compagnon).

⚠️ Toujours des **chemins absolus** dans le `.env` : quand le service tourne en
root, `~` pointe vers `/root`, pas vers le home de l'utilisateur.

## Configurer les alertes email (Resend)

`RESEND_API_KEY`/`ALERT_EMAIL_TO`/`ALERT_EMAIL_FROM` sont à votre charge, comme
`RCLONE_REMOTE` — rien n'est câblé en dur. Étapes :

1. Créer un compte [Resend](https://resend.com) (gratuit pour un usage bas
   volume) et générer une clé API.
2. Vérifier votre propre domaine d'envoi dans Resend (DKIM + SPF chez votre
   fournisseur DNS) — l'expéditeur par défaut `onboarding@resend.dev` échoue
   dès qu'on écrit à quelqu'un d'autre que le titulaire du compte, et part
   souvent en indésirables (domaine partagé, pas de DKIM/SPF au nom de
   l'expéditeur réel).
3. Renseigner `ALERT_EMAIL_FROM=alertes@votre-domaine` une fois le domaine
   vérifié.

## Quota Drive multi-comptes

Si plusieurs serveurs sauvegardent vers des comptes Drive distincts (un par
machine), un incident sur l'un n'affecte pas l'autre. Un compte Google One
payant (100-200 Go) donne une bonne marge ; le palier gratuit (15 Go) suffit
largement si les snapshots GFS pèsent quelques Mo/jour — ce qui pèse surtout,
c'est `workspace-latest/` (code + docs), qui ne grossit pas avec le temps une
fois stabilisé.

### Limites connues de l'auto-discovery

Sur un serveur où le service tourne sans privilèges root, certaines données
montées en **bind-mount** plutôt qu'en volume Docker nommé échappent à la
découverte automatique des volumes, et doivent être exclues explicitement
(chacune pour une raison constatée en conditions réelles — sinon fausse alerte
à chaque run) :

| Type de chemin exclu | Raison typique | Conséquence |
|---|---|---|
| Certificats TLS en root 600 | illisibles sans privilèges | aucune — un reverse-proxy à la Let's Encrypt les réémet au redémarrage |
| Données Postgres brutes en bind-mount | déjà couvertes par `pg_dump` | aucune — copie brute non restaurable entre versions majeures |
| Base de données vivante (ex: MariaDB) hors dump dédié | socket + journaux réécrits pendant la copie | l'historique n'a alors aucune copie cloud tant qu'un dump dédié n'est pas ajouté |
| Journaux SQLite `.db-wal`/`.db-shm` | réécrits en cours de copie | restauration en « meilleur effort » |

Couvrir proprement une base non-Postgres demande une étape de **dump**
(`mysqldump`, etc.) dans le conteneur plutôt qu'une copie de fichiers — le même
traitement que Postgres, mais adapté au moteur. Ce n'est pas un cas générique
que l'auto-discovery actuelle sait traiter automatiquement.

⚠️ Avertissement rclone possible à chaque run : *« This remote uses rclone's
shared Google Drive client_id, which is being retired... »*. Pas bloquant à
court terme, mais prévoir de créer un client_id Google Cloud dédié si Google
retire le partagé.

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
