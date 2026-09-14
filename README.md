# server-backup-gdrive

Sauvegarde quotidienne **portable** d'un serveur Linux vers Google Drive (via
[rclone](https://rclone.org/)), en GFS (daily/weekly/monthly) avec rétention
configurable. Un seul script, aucun nom de machine en dur : tout ce qui est
spécifique à un serveur vit dans un `.env` local, jamais commité.

## Ce qu'il sauvegarde — par découverte, pas par liste

Rien n'est énuméré à la main : ce qui est trouvé sur la machine est
sauvegardé, donc un nouveau service déployé est couvert dès le lendemain sans
toucher au script.

| Source | Détection | Destination |
|---|---|---|
| Bases Postgres | tout conteneur Docker actif dont l'environnement porte `POSTGRES_DB` → `pg_dump` | `databases/<conteneur>.sql.gz` |
| Volumes Docker | tous les volumes **nommés**, sauf ceux exclus dans la config | `volumes/<volume>.tar.gz` |
| Code et docs | un dossier de travail configurable | tar horodaté + synchro incrémentale |
| Configs critiques | une liste de chemins configurable | `configs/<chemin-aplati>.tar.gz` |

- Rétention GFS configurable (défaut 14 jours / 8 semaines / 12 mois), avec
  copie serveur-à-serveur côté Drive (aucun octet ne remonte deux fois).
- Alertes par mail (via [Resend](https://resend.com)) à chaque run, succès
  compris — l'absence de mail est elle-même le signal d'alerte.
- Pensé pour un parc multi-serveurs : chaque machine se sauvegarde
  elle-même, pas de dépendance SSH entre serveurs.

## Installation

```bash
git clone https://github.com/Tangoal/server-backup-gdrive.git
cd server-backup-gdrive
cp .env.example .env && chmod 600 .env   # puis remplir (voir commentaires du fichier)
rclone listremotes                       # le remote configuré doit exister
bash backup.sh                           # premier run à la main

sudo bash install.sh root      # ou un autre utilisateur, selon la machine
```

`install.sh` génère l'unité systemd (service + timer quotidien) à partir du
chemin réel d'installation et de l'utilisateur passé en argument — jamais
committée en dur, pour que le même dépôt puisse être cloné tel quel sur
plusieurs serveurs.

## Documentation

Détails de conception, pièges rencontrés et procédure de restauration :
[`AGENTS.md`](./AGENTS.md).

## Licence

MIT.
