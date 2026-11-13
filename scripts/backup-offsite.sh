#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Transfer a finished, encrypted backup directory to an operator-chosen offsite target and verify it.
set -euo pipefail
fail() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
case "${1:-}" in
  --help|-h)
    cat <<'TXT'
Aufruf: FORM_BACKUP_OFFSITE_METHOD=rclone|rsync FORM_BACKUP_OFFSITE_TARGET=ZIEL scripts/backup-offsite.sh BACKUPVERZEICHNIS [--dry-run]
  rclone: ZIEL = remote:pfad (rclone copy + rclone check)
  rsync:  ZIEL = [benutzer@]host:/pfad oder lokaler Pfad (rsync über ssh, danach Prüfsummenvergleich)
  FORM_BACKUP_OFFSITE_SSH_OPTS: optionale ssh-Optionen für rsync (z. B. "-i /geschuetzt/id -o IdentitiesOnly=yes")
Übertragen werden nur verschlüsselte Daten, SHA256SUMS, counts.tsv, source-database und encryption-Marker.
TXT
    exit 0 ;;
esac
dir=${1:?Backupverzeichnis fehlt}; shift
DRY=0
case "${1:-}" in --dry-run) DRY=1; shift ;; esac
(( $# == 0 )) || fail 'Unbekannte Argumente'
method=${FORM_BACKUP_OFFSITE_METHOD:-}
target=${FORM_BACKUP_OFFSITE_TARGET:-}
[[ "$method" == rclone || "$method" == rsync ]] || fail 'FORM_BACKUP_OFFSITE_METHOD muss rclone oder rsync sein'
[[ -n "$target" && "$target" != -* ]] || fail 'FORM_BACKUP_OFFSITE_TARGET fehlt'
[[ -d "$dir" ]] || fail 'Backupverzeichnis fehlt'
dir=${dir%/}
name=$(basename "$dir")
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'Verzeichnisname enthält unerlaubte Zeichen'
# Refuse anything but the expected encrypted layout: plaintext SQL must never leave the server.
[[ -f "$dir/SHA256SUMS" ]] || fail 'SHA256SUMS fehlt'
[[ ! -e "$dir/database.sql" ]] || fail 'Klartext-Dump (database.sql) liegt vor; Übertragung verweigert'
data=()
for f in database.sql.age database.sql.gpg; do [[ ! -e "$dir/$f" ]] || data+=("$f"); done
(( ${#data[@]} == 1 )) || fail 'Genau eine verschlüsselte Datendatei erwartet (database.sql.age oder .gpg)'
for f in "$dir"/*; do
  case "$(basename "$f")" in database.sql.age|database.sql.gpg|SHA256SUMS|counts.tsv|source-database) ;; *) fail "Unerwartete Datei: $(basename "$f")" ;; esac
done
# Local integrity first: the checksums must match before anything is uploaded.
(cd "$dir" && while read -r digest file; do
  [[ "$(openssl dgst -sha256 "$file" | awk '{print $NF}')" == "$digest" ]] || { echo "Prüfsumme falsch: $file" >&2; exit 1; }
done < SHA256SUMS) || fail 'Lokale Prüfsummen stimmen nicht'
if [[ "$DRY" == 1 ]]; then
  echo "Trockenlauf: $method-Übertragung von $name nach $target/$name mit anschließender Prüfsummenverifikation; keine Änderungen."
  exit 0
fi
case "$method" in
  rclone)
    command -v rclone >/dev/null || fail 'rclone fehlt'
    rclone copy "$dir" "$target/$name"
    rclone check "$dir" "$target/$name" ;;
  rsync)
    command -v rsync >/dev/null || fail 'rsync fehlt'
    # shellcheck disable=SC2206
    ssh_cmd=(ssh -o BatchMode=yes ${FORM_BACKUP_OFFSITE_SSH_OPTS:-})
    rsync -rt --chmod=D700,F600 -e "${ssh_cmd[*]}" "$dir/" "$target/$name/"
    # Verification: checksum-based dry run must report no differences.
    diffs=$(rsync -rc --dry-run --itemize-changes -e "${ssh_cmd[*]}" "$dir/" "$target/$name/")
    [[ -z "$diffs" ]] || fail "Verifikation fehlgeschlagen, Abweichungen: $diffs" ;;
esac
echo "Offsite-Übertragung von $name nach $target verifiziert (Prüfsummenvergleich)."
