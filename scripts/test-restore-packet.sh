#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Behaviour test for the max_allowed_packet guard of scripts/restore-db.sh (no DB, no Docker: a stub `mariadb` on PATH).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/backup"
export STUB_LOG="$WORK/log"
cat > "$WORK/bin/mariadb" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
sql=""; prev=""
for a in "$@"; do [[ "$prev" == -e ]] && sql=$a; prev=$a; done
case "$sql" in
  *max_allowed_packet*) echo "${STUB_PACKET:-}" ;;
  "SELECT TABLE_NAME"*) echo entries ;;
  "SELECT COUNT"*) echo 2 ;;
  *) cat >/dev/null </dev/stdin || true ;;
esac
STUB
chmod +x "$WORK/bin/mariadb"
printf 'x' > "$WORK/pw"
printf 'entries\t2\n' > "$WORK/backup/counts.tsv"
printf 'form\n' > "$WORK/backup/source-database"
# 80 MiB single dump line: the shape of a sealed 40 MiB object as --hex-blob.
head -c $((80 * 1024 * 1024)) /dev/zero | tr '\0' 'a' > "$WORK/backup/database.sql"
digest() { openssl dgst -sha256 "$1" | awk '{print $NF}'; }
for f in database.sql counts.tsv source-database; do printf '%s  %s\n' "$(digest "$WORK/backup/$f")" "$f"; done > "$WORK/backup/SHA256SUMS"

run_restore() {
  : > "$STUB_LOG"
  PATH="$WORK/bin:$PATH" DB_CLIENT_MODE=local FORM_DB_HOST=db.example.invalid FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1 \
    FORM_BACKUP_ALLOW_PLAINTEXT=1 FORM_DB_PASSWORD_FILE="$WORK/pw" "$ROOT/scripts/restore-db.sh" "$WORK/backup" restore_probe 2>&1
}
fail() { echo "FEHLER: $*" >&2; exit 1; }

# 1. Server limit 64 MiB < dump line 80 MiB: abort BEFORE CREATE DATABASE, clear message.
out=$(STUB_PACKET=67108864 run_restore) && fail 'Restore mit 64M haette abbrechen muessen'
grep -q 'max_allowed_packet' <<<"$out" || fail "Meldung nennt max_allowed_packet nicht: $out"
grep -q 'CREATE DATABASE' "$STUB_LOG" && fail 'CREATE DATABASE trotz zu kleinem Limit ausgefuehrt'

# 2. Server limit 256 MiB: restore runs.
out=$(STUB_PACKET=268435456 run_restore) || fail "Restore mit 256M scheiterte: $out"
grep -q 'CREATE DATABASE' "$STUB_LOG" || fail 'CREATE DATABASE fehlt'
grep -q -- '--max-allowed-packet' "$STUB_LOG" || fail 'Importclient ohne --max-allowed-packet'

# 3. Limit unknown (empty answer): warn, but do not block.
out=$(STUB_PACKET= run_restore) || fail "Restore bei unbekanntem Limit scheiterte: $out"
grep -qi 'warnung' <<<"$out" || fail 'Keine Warnung bei unbekanntem Limit'

# 4. Small dump and 64 MiB limit is fine (only the recommendation warning).
head -c 1000 /dev/zero | tr '\0' 'a' > "$WORK/backup/database.sql"
for f in database.sql counts.tsv source-database; do printf '%s  %s\n' "$(digest "$WORK/backup/$f")" "$f"; done > "$WORK/backup/SHA256SUMS"
out=$(STUB_PACKET=67108864 run_restore) || fail "Kleiner Dump bei 64M scheiterte: $out"
grep -qi 'warnung' <<<"$out" || fail 'Keine Empfehlungswarnung bei 64M'
echo 'test-restore-packet: ok'
