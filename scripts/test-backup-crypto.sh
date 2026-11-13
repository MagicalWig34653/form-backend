#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Restore proof for encrypted backups against a throwaway MariaDB container (own name/port, removed afterwards).
# Synthetic data only. age cases run only when `age` is installed; gpg cases run when `gpg` is installed.
set -euo pipefail
cd "$(dirname "$0")/.."
S=$PWD/scripts
CONTAINER=form-backup-probe-db
PORT=${PROBE_DB_PORT:-23399}
# Docker must see the dir (macOS Docker shares $HOME, not always /tmp); keep the path short for gpg-agent sockets.
mkdir -p "${PROBE_TMP:=$HOME/.cache}"
WORK=$(mktemp -d "$PROBE_TMP/fbp.XXXXXX")
PASS=0; FAIL=0
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [[ -z "${GNUPGHOME:-}" ]] || gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
ok() { PASS=$((PASS+1)); printf 'OK    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FEHLER %s\n' "$1"; }
expect_ok() { local name=$1; shift; if "$@" >"$WORK/out" 2>&1; then ok "$name"; else bad "$name"; sed 's/^/    /' "$WORK/out"; fi; }
expect_fail() { local name=$1; shift; if "$@" >"$WORK/out" 2>&1; then bad "$name (sollte scheitern)"; else ok "$name"; fi; }

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --tmpfs /var/lib/mysql -e MARIADB_ROOT_PASSWORD=probe -p "127.0.0.1:$PORT:3306" mariadb:12.3 >/dev/null
for _ in $(seq 1 60); do
  docker exec "$CONTAINER" mariadb -uroot -pprobe -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 1
done
sql() { docker exec -i "$CONTAINER" mariadb -uroot -pprobe "$@"; }

printf probe > "$WORK/pw"
export FORM_DB_HOST=host.docker.internal FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_NAME=probe_src
export FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1 FORM_DB_PASSWORD_FILE=$WORK/pw
unset FORM_BACKUP_AGE_RECIPIENTS_FILE FORM_BACKUP_GPG_RECIPIENT FORM_BACKUP_GPG_PUBKEY_FILE FORM_BACKUP_ALLOW_PLAINTEXT || true

# Synthetic data; secret_blob stands in for a server-key-encrypted package (openssl AES, key file = stand-in for the server key).
head -c 32 /dev/urandom | base64 > "$WORK/server-key"
cipher=$(printf 'synthetic-secret-plaintext' | openssl enc -aes-256-cbc -pbkdf2 -pass "file:$WORK/server-key" -base64 -A)
sql -e 'DROP DATABASE IF EXISTS probe_src; CREATE DATABASE probe_src CHARACTER SET utf8mb4'
sql probe_src -e "CREATE TABLE entries (id INT PRIMARY KEY, body TEXT, secret_blob TEXT); INSERT INTO entries VALUES (1,'Müller ä','$cipher'),(2,'zwei',NULL),(3,'drei',NULL); CREATE TABLE leer (id INT)"

# 1) fail-closed without recipient
expect_fail 'Backup ohne Empfaenger bricht ab' "$S/backup-db.sh" "$WORK/b-none"
[[ ! -e "$WORK/b-none/database.sql" ]] && ok 'kein Klartext-Dump ohne Empfaenger' || bad 'Klartext-Dump liegt vor'
FORM_BACKUP_ALLOW_PLAINTEXT=1 "$S/backup-db.sh" "$WORK/b-plain" >"$WORK/out" 2>&1 || { bad 'Klartext mit ALLOW_PLAINTEXT'; }
grep -qi 'warnung' "$WORK/out" && ok 'laute Klartext-Warnung' || bad 'keine Klartext-Warnung'
expect_fail 'Restore verweigert Klartext ohne ALLOW_PLAINTEXT' "$S/restore-db.sh" "$WORK/b-plain" restore_plain

count_ok() { # db
  local n; n=$(sql -N -B "$1" -e 'SELECT COUNT(*) FROM entries'); [[ $n == 3 ]]
}

if command -v gpg >/dev/null; then
  export GNUPGHOME=$WORK/gh; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-generate-key 'probe@example.invalid' rsa3072 encr never 2>/dev/null
  gpg --batch --armor --export probe@example.invalid > "$WORK/pub.asc"
  GNUPG_REAL=$GNUPGHOME
  # wrong keyring: independent empty home
  mkdir -m 700 "$WORK/gh-wrong"
  export FORM_BACKUP_GPG_RECIPIENT=probe@example.invalid FORM_BACKUP_GPG_PUBKEY_FILE=$WORK/pub.asc
  expect_ok 'gpg: Backup' "$S/backup-db.sh" "$WORK/b-gpg"
  [[ -f "$WORK/b-gpg/database.sql.gpg" && ! -e "$WORK/b-gpg/database.sql" ]] && ok 'gpg: nur Chiffrat im Verzeichnis' || bad 'gpg: Dateien unerwartet'
  grep -q 'Müller' "$WORK/b-gpg/database.sql.gpg" && bad 'gpg: Klartext im Chiffrat' || ok 'gpg: kein Klartext im Chiffrat'
  grep -q database.sql.gpg "$WORK/b-gpg/SHA256SUMS" && ok 'gpg: SHA256SUMS deckt Chiffrat' || bad 'gpg: SHA256SUMS ohne Chiffrat'
  [[ $(stat -f %Lp "$WORK/b-gpg/database.sql.gpg" 2>/dev/null | grep -E '^[0-7]{3,4}$' || stat -c %a "$WORK/b-gpg/database.sql.gpg") == 600 ]] && ok 'gpg: Chiffrat 0600' || bad 'gpg: Modus'
  # restore with right keyring
  export FORM_BACKUP_GPG_HOME=$GNUPG_REAL
  expect_ok 'gpg: Restore' "$S/restore-db.sh" "$WORK/b-gpg" restore_gpg
  count_ok restore_gpg && ok 'gpg: Zeilenzahlen gleich (3)' || bad 'gpg: Zeilenzahl'
  # Server-key stand-in: ciphertext stays readable after restore with the same key.
  back=$(sql -N -B restore_gpg -e 'SELECT secret_blob FROM entries WHERE id=1' | openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$WORK/server-key" -base64 -A)
  [[ $back == synthetic-secret-plaintext ]] && ok 'Server-Key-Stellvertreter: Chiffrat nach Restore mit demselben Key lesbar' || bad 'Chiffrat nach Restore nicht lesbar'
  head -c 32 /dev/urandom | base64 > "$WORK/other-key"
  sql -N -B restore_gpg -e 'SELECT secret_blob FROM entries WHERE id=1' | openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$WORK/other-key" -base64 -A >/dev/null 2>&1 \
    && bad 'neuer Key liest altes Chiffrat' || ok 'anderer Key kann Chiffrat nicht lesen'
  # wrong key
  FORM_BACKUP_GPG_HOME=$WORK/gh-wrong expect_fail 'gpg: falscher Schluessel schlaegt fehl' "$S/restore-db.sh" "$WORK/b-gpg" restore_gpgwrong
  n=$(sql -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='restore_gpgwrong'")
  [[ $n == 0 ]] && ok 'gpg: falscher Schluessel legt keine DB an' || bad 'gpg: DB trotz falschem Schluessel angelegt'
  # tampered
  cp -R "$WORK/b-gpg" "$WORK/b-gpg-t"; printf 'x' >> "$WORK/b-gpg-t/database.sql.gpg"
  expect_fail 'gpg: manipuliertes Chiffrat scheitert' "$S/restore-db.sh" "$WORK/b-gpg-t" restore_gpgt
  grep -q 'Prüfsummen' "$WORK/out" && ok 'gpg: Abbruch an der Pruefsumme' || bad 'gpg: nicht an Pruefsumme gescheitert'
  # offsite via rsync to local path, then verify, then tamper detection
  export FORM_BACKUP_OFFSITE_METHOD=rsync FORM_BACKUP_OFFSITE_TARGET=$WORK/offsite
  mkdir "$WORK/offsite"
  expect_ok 'Offsite: rsync-Upload mit Verifikation' "$S/backup-offsite.sh" "$WORK/b-gpg"
  [[ -f "$WORK/offsite/b-gpg/database.sql.gpg" ]] && ok 'Offsite: Chiffrat am Ziel' || bad 'Offsite: Datei fehlt'
  expect_ok 'Offsite: Trockenlauf' "$S/backup-offsite.sh" "$WORK/b-gpg" --dry-run
  expect_fail 'Offsite: Klartext-Backup wird nicht uebertragen' "$S/backup-offsite.sh" "$WORK/b-plain"
  unset FORM_BACKUP_OFFSITE_METHOD FORM_BACKUP_OFFSITE_TARGET
  expect_fail 'Offsite: ohne Ziel Abbruch' "$S/backup-offsite.sh" "$WORK/b-gpg"
  # stubbed rclone: command line
  mkdir "$WORK/bin"; printf '#!/bin/sh\necho "rclone $*" >> "%s/rclone.log"\n' "$WORK" > "$WORK/bin/rclone"; chmod +x "$WORK/bin/rclone"
  PATH="$WORK/bin:$PATH" FORM_BACKUP_OFFSITE_METHOD=rclone FORM_BACKUP_OFFSITE_TARGET=remote:bucket/form "$S/backup-offsite.sh" "$WORK/b-gpg" >/dev/null 2>&1 || true
  grep -q 'rclone copy' "$WORK/rclone.log" && grep -q 'rclone check' "$WORK/rclone.log" && ok 'Offsite: rclone copy + check (Stub)' || bad 'Offsite: rclone-Aufrufe fehlen'
fi

if command -v age >/dev/null; then
  age-keygen -o "$WORK/age-id" >/dev/null 2>&1
  age-keygen -y "$WORK/age-id" > "$WORK/age-recipients"
  age-keygen -o "$WORK/age-id-wrong" >/dev/null 2>&1
  unset FORM_BACKUP_GPG_RECIPIENT FORM_BACKUP_GPG_PUBKEY_FILE
  export FORM_BACKUP_AGE_RECIPIENTS_FILE=$WORK/age-recipients
  expect_ok 'age: Backup' "$S/backup-db.sh" "$WORK/b-age"
  [[ -f "$WORK/b-age/database.sql.age" && ! -e "$WORK/b-age/database.sql" ]] && ok 'age: nur Chiffrat' || bad 'age: Dateien'
  FORM_BACKUP_AGE_IDENTITY_FILE=$WORK/age-id expect_ok 'age: Restore' "$S/restore-db.sh" "$WORK/b-age" restore_age
  count_ok restore_age && ok 'age: Zeilenzahlen gleich' || bad 'age: Zeilenzahl'
  FORM_BACKUP_AGE_IDENTITY_FILE=$WORK/age-id-wrong expect_fail 'age: falscher Schluessel' "$S/restore-db.sh" "$WORK/b-age" restore_agew
  cp -R "$WORK/b-age" "$WORK/b-age-t"; printf 'x' >> "$WORK/b-age-t/database.sql.age"
  FORM_BACKUP_AGE_IDENTITY_FILE=$WORK/age-id expect_fail 'age: manipuliertes Chiffrat' "$S/restore-db.sh" "$WORK/b-age-t" restore_aget
else
  echo 'HINWEIS: age nicht installiert, age-Faelle uebersprungen (UNGETESTET)'
fi

# Prune: only old, pattern-named, never the newest
export FORM_BACKUP_PRUNE_NOW_EPOCH=1800000000   # fixed clock
R=$WORK/root; mkdir "$R"
mk() { mkdir "$R/$1"; printf x > "$R/$1/SHA256SUMS"; }
mk form-backup-20260101T000000Z   # old
mk form-backup-20260102T000000Z   # old
mk form-backup-20270101T000000Z   # recent (now is 2027-01-15)
mkdir "$R/andere-daten"; printf x > "$R/andere-daten/SHA256SUMS"
expect_ok 'Prune: Trockenlauf' "$S/backup-prune.sh" "$R" --dry-run
[[ -d "$R/form-backup-20260101T000000Z" ]] && ok 'Prune: Trockenlauf loescht nichts' || bad 'Prune: Trockenlauf loescht'
FORM_BACKUP_RETENTION_DAYS=30 expect_ok 'Prune: Lauf' "$S/backup-prune.sh" "$R"
[[ ! -e "$R/form-backup-20260101T000000Z" && ! -e "$R/form-backup-20260102T000000Z" && -d "$R/form-backup-20270101T000000Z" && -d "$R/andere-daten" ]] \
  && ok 'Prune: nur Altes mit Muster geloescht' || bad 'Prune: falsche Auswahl'
R2=$WORK/root2; mkdir "$R2"; mkdir "$R2/form-backup-20200101T000000Z"; printf x > "$R2/form-backup-20200101T000000Z/SHA256SUMS"
FORM_BACKUP_RETENTION_DAYS=1 "$S/backup-prune.sh" "$R2" >/dev/null 2>&1 || true
[[ -d "$R2/form-backup-20200101T000000Z" ]] && ok 'Prune: juengstes Backup bleibt immer' || bad 'Prune: juengstes geloescht'
FORM_BACKUP_RETENTION_DAYS=0 expect_fail 'Prune: Frist 0 abgelehnt' "$S/backup-prune.sh" "$R"
FORM_BACKUP_RETENTION_DAYS=abc expect_fail 'Prune: ungueltige Frist abgelehnt' "$S/backup-prune.sh" "$R"

# strip_definer (restore without SET USER privilege): DEFINER disappears from CREATE lines of triggers/routines, data lines stay untouched
# shellcheck source=scripts/db-common.sh
( source "$S/db-common.sh" 2>/dev/null; declare -f strip_definer >/dev/null ) && {
  eval "$(sed -n '/^strip_definer()/p' "$S/db-common.sh")"
  IN=$'/*!50003 CREATE*/ /*!50017 DEFINER=`form`@`%`*/ /*!50003 TRIGGER t BEFORE INSERT ON x FOR EACH ROW SET NEW.a=1 */;;\nCREATE DEFINER=`a`@`b` PROCEDURE p() BEGIN END;;\nINSERT INTO t VALUES (\'CREATE DEFINER=`x`@`y` bleibt\');'
  OUT=$(printf '%s\n' "$IN" | strip_definer)
  L1=$(printf '%s\n' "$OUT" | sed -n 1p); L2=$(printf '%s\n' "$OUT" | sed -n 2p); L3=$(printf '%s\n' "$OUT" | sed -n 3p)
  [[ "$L1" != *DEFINER* && "$L1" == *'TRIGGER t BEFORE INSERT'* ]] && ok 'strip_definer: Trigger-Zeile ohne DEFINER, Rest bleibt' || bad "strip_definer Trigger: $L1"
  [[ "$L2" == 'CREATE PROCEDURE p() BEGIN END;;' ]] && ok 'strip_definer: Routine ohne DEFINER' || bad "strip_definer Routine: $L2"
  [[ "$L3" == *'DEFINER=`x`@`y` bleibt'* ]] && ok 'strip_definer: Datenzeile unveraendert' || bad "strip_definer Daten: $L3"
} || bad 'strip_definer fehlt in db-common.sh'

printf '\n%d bestanden, %d fehlgeschlagen\n' "$PASS" "$FAIL"
[[ $FAIL == 0 ]]
