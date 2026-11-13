#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Delete backups older than the retention period. Only directories named form-backup-YYYYMMDDTHHMMSSZ
# that contain SHA256SUMS; the newest such backup is never deleted. Age comes from the name, not mtime.
set -euo pipefail
fail() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
case "${1:-}" in
  --help|-h)
    cat <<'TXT'
Aufruf: [FORM_BACKUP_RETENTION_DAYS=30] scripts/backup-prune.sh BACKUPWURZEL [--dry-run] [--offsite]
  Standard 30 Tage (nur Voreinstellung; die Frist legt die Klinik fest, AVV § 12).
  --offsite löscht zusätzlich am rclone-Ziel (FORM_BACKUP_OFFSITE_METHOD=rclone, FORM_BACKUP_OFFSITE_TARGET).
  Bei rsync/ssh-Zielen und Append-only/Objektsperre löscht der Anbieter per Lifecycle-Regel.
TXT
    exit 0 ;;
esac
root=${1:?Backupwurzel fehlt}; shift
DRY=0; OFFSITE=0
while (( $# )); do
  case "$1" in --dry-run) DRY=1 ;; --offsite) OFFSITE=1 ;; *) fail 'Unbekannte Argumente' ;; esac
  shift
done
days=${FORM_BACKUP_RETENTION_DAYS:-30}
[[ "$days" =~ ^[1-9][0-9]{0,3}$ ]] || fail 'FORM_BACKUP_RETENTION_DAYS muss eine ganze Zahl >= 1 sein'
[[ -d "$root" ]] || fail 'Backupwurzel fehlt'
now=${FORM_BACKUP_PRUNE_NOW_EPOCH:-$(date -u +%s)}
[[ "$now" =~ ^[0-9]+$ ]] || fail 'Ungültige Uhrzeit'
cut=$(( now - days * 86400 ))
if cutoff=$(date -u -d "@$cut" +%Y%m%dT%H%M%SZ 2>/dev/null); then :; else cutoff=$(date -u -r "$cut" +%Y%m%dT%H%M%SZ); fi
if [[ "$OFFSITE" == 1 ]]; then
  [[ "${FORM_BACKUP_OFFSITE_METHOD:-}" == rclone && -n "${FORM_BACKUP_OFFSITE_TARGET:-}" ]] || fail '--offsite benötigt FORM_BACKUP_OFFSITE_METHOD=rclone und FORM_BACKUP_OFFSITE_TARGET'
  command -v rclone >/dev/null || fail 'rclone fehlt'
fi
pattern='^form-backup-[0-9]{8}T[0-9]{6}Z$'
names=()
for d in "$root"/form-backup-*; do
  [[ -d "$d" && ! -L "$d" ]] || continue
  n=$(basename "$d")
  [[ "$n" =~ $pattern && -f "$d/SHA256SUMS" ]] || continue
  names+=("$n")
done
(( ${#names[@]} > 0 )) || { echo 'Keine Backups mit erwartetem Namen gefunden.'; exit 0; }
newest=$(printf '%s\n' "${names[@]}" | sort | tail -n 1)
removed=0
for n in "${names[@]}"; do
  stamp=${n#form-backup-}
  [[ "$n" != "$newest" && "$stamp" < "$cutoff" ]] || continue
  if [[ "$DRY" == 1 ]]; then echo "Trockenlauf: würde löschen: $n"; else
    rm -rf -- "${root:?}/$n"; echo "Gelöscht: $n"
    [[ "$OFFSITE" == 0 ]] || rclone purge "$FORM_BACKUP_OFFSITE_TARGET/$n"
  fi
  removed=$((removed+1))
done
echo "Aufbewahrung $days Tage (Stichtag $cutoff): $removed Backup(s) ${DRY/1/nur angezeigt}; neuestes ($newest) bleibt immer."
