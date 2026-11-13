#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Restore only trusted dumps, into a newly created database; never drop or reuse an existing one.
set -euo pipefail
# shellcheck source=scripts/db-common.sh
source "$(dirname "$0")/db-common.sh"
# shellcheck source=scripts/backup-crypto.sh
source "$(dirname "$0")/backup-crypto.sh"
case "${1:-}" in
  --help|-h) echo 'Aufruf: FORM_DB_HOST=HOST FORM_DB_PASSWORD_FILE=DATEI scripts/restore-db.sh BACKUPVERZEICHNIS restore_NEUER_NAME [--dry-run]'; exit 0 ;;
esac
backup=${1:?Backupverzeichnis fehlt}; target=${2:?Neue Zieldatenbank fehlt}; shift 2
DRY=0
case "${1:-}" in --dry-run) DRY=1; shift ;; esac
(( $# == 0 )) || db_fail 'Unbekannte Argumente'
[[ "$target" =~ ^restore_[a-zA-Z0-9_]{1,55}$ ]] || db_fail 'Ziel muss restore_ heißen und darf nur Buchstaben/Ziffern/_ enthalten'
if [[ "$DRY" == 1 ]]; then
  echo "Trockenlauf: Prüfsummen prüfen; CREATE DATABASE $target ohne IF NOT EXISTS; Import und Zeilenzahlen vergleichen."
  exit 0
fi
db_init
[[ -d "$backup" ]] || db_fail 'Backupverzeichnis fehlt'
crypto_detect "$backup"
expected=$(mktemp)
actual=$(mktemp)
trap 'rm -f "$expected" "$actual"' EXIT
for file in "$BACKUP_DATA_FILE" counts.tsv source-database; do
  digest=$(checksum "$backup/$file")
  printf '%s  %s\n' "$digest" "$file"
done > "$expected"
cmp "$backup/SHA256SUMS" "$expected" || db_fail 'Prüfsummen stimmen nicht überein'
# No --databases in the dump: unqualified application tables are imported into this new schema.
# Probe the first plaintext byte before creating anything: a wrong key must not leave an empty database behind.
probe=$(mktemp)
trap 'rm -f "$expected" "$actual" "$probe"' EXIT
set +e
crypto_decrypt "$backup/$BACKUP_DATA_FILE" 2>"$probe" | head -c 1 >/dev/null
status=("${PIPESTATUS[@]}")
set -e
[[ "${status[0]}" == 0 || "${status[0]}" == 141 ]] || { cat "$probe" >&2; db_fail 'Entschlüsselung fehlgeschlagen (falscher Schlüssel?)'; }
db_tool mariadb -e "CREATE DATABASE \`$target\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
crypto_decrypt "$backup/$BACKUP_DATA_FILE" | strip_definer | db_tool mariadb "$target"
db_counts "$target" > "$actual"
diff -u "$backup/counts.tsv" "$actual"
echo "Restore geprüft: Zeilenzahlen in $target stimmen überein. DB bleibt zur fachlichen Prüfung bestehen."
