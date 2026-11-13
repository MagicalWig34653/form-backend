#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
# shellcheck source=scripts/db-common.sh
source "$(dirname "$0")/db-common.sh"
# shellcheck source=scripts/backup-crypto.sh
source "$(dirname "$0")/backup-crypto.sh"
case "${1:-}" in
  --help|-h) echo 'Aufruf: FORM_DB_HOST=HOST FORM_DB_PASSWORD_FILE=DATEI scripts/backup-db.sh NEUES_VERZEICHNIS [--dry-run]'; exit 0 ;;
esac
output=${1:?Neues Backupverzeichnis fehlt}; shift
DRY=0
case "${1:-}" in --dry-run) DRY=1; shift ;; esac
(( $# == 0 )) || db_fail 'Unbekannte Argumente'
[[ ! -e "$output" ]] || db_fail 'Backupverzeichnis muss neu sein'
if [[ "$DRY" == 1 ]]; then
  crypto_select
  echo "Trockenlauf: neues Verzeichnis (0700), konsistenter MariaDB-Dump per Pipe in Verschlüsselung ($BACKUP_CRYPTO), Zeilenzahlen und Prüfsummen; keine Änderungen."
  exit 0
fi
crypto_select
db_init
umask 077
mkdir "$output"
trap crypto_cleanup EXIT
trap 'echo "Backup unvollständig; Verzeichnis verwerfen oder prüfen." >&2' ERR
db_tool mariadb-dump --single-transaction --quick --hex-blob \
  --routines --events --triggers --skip-add-locks --skip-add-drop-table "$FORM_DB_NAME" | crypto_encrypt > "$output/$BACKUP_DATA_FILE"
db_counts "$FORM_DB_NAME" > "$output/counts.tsv"
printf '%s\n' "$FORM_DB_NAME" > "$output/source-database"
for file in "$BACKUP_DATA_FILE" counts.tsv source-database; do
  digest=$(checksum "$output/$file")
  printf '%s  %s\n' "$digest" "$file"
done > "$output/SHA256SUMS"
echo 'Backup erstellt. Schreibpause muss Dump UND Zählung umfassen. Server-Key separat verschlüsselt sichern.'
[[ "$BACKUP_CRYPTO" == none ]] || echo "Verschlüsselt mit $BACKUP_CRYPTO; der private Schlüssel liegt nicht auf diesem Server."
