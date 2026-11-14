#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# External MariaDB client helpers. The container runs a client, never a DB server.
set -euo pipefail

db_fail() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
db_init() {
  : "${FORM_DB_HOST:?FORM_DB_HOST muss auf die externe MariaDB zeigen}"
  : "${FORM_DB_PORT:=3306}" "${FORM_DB_USER:=form}" "${FORM_DB_NAME:=form}" "${FORM_DB_TLS:=verify}"
  : "${FORM_ALLOW_INSECURE_DEV:=0}" "${DB_CONNECT_TIMEOUT:=10}" "${DB_CLIENT_IMAGE:=mariadb:12.3}" "${DB_CLIENT_MEMORY:=256m}"
  : "${DB_CLIENT_CA_PATH:=/run/form-db-ca}"
  : "${DB_CLIENT_MODE:=docker}" "${DB_CLIENT_NETWORK:=${NETWORK_NAME:-}}" "${DB_TLS_CA_FILE:=}"
  DB_PASSWORD_INPUT_FILE=${DB_PASSWORD_SOURCE_FILE:-${FORM_DB_PASSWORD_FILE:-}}
  [[ -z "${FORM_DB_PASSWORD:-}" || -z "$DB_PASSWORD_INPUT_FILE" ]] || db_fail 'Passwort und Passwortdatei sind beide gesetzt'
  if [[ -z "${FORM_DB_PASSWORD:-}" ]]; then
    [[ -n "$DB_PASSWORD_INPUT_FILE" && -r "$DB_PASSWORD_INPUT_FILE" && -s "$DB_PASSWORD_INPUT_FILE" ]] || db_fail 'FORM_DB_PASSWORD oder lesbare FORM_DB_PASSWORD_FILE/DB_PASSWORD_SOURCE_FILE fehlt'
    [[ "$DB_PASSWORD_INPUT_FILE" == /* ]] || DB_PASSWORD_INPUT_FILE="$PWD/$DB_PASSWORD_INPUT_FILE"
  fi
  [[ "$FORM_DB_HOST" != -* && "$FORM_DB_PORT" =~ ^[0-9]{1,5}$ ]] || db_fail 'Ungültige DB-Verbindung'
  (( 10#$FORM_DB_PORT >= 1 && 10#$FORM_DB_PORT <= 65535 )) || db_fail 'Ungültiger DB-Port'
  [[ "$FORM_DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]] || db_fail 'Ungültiger FORM_DB_NAME'
  [[ "$FORM_DB_USER" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$ ]] || db_fail 'Ungültiger FORM_DB_USER'
  [[ "$DB_CONNECT_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || db_fail 'Ungültiger DB_CONNECT_TIMEOUT'
  case "$FORM_DB_TLS" in
    verify) ;;
    disable) [[ "$FORM_ALLOW_INSECURE_DEV" == 1 ]] || db_fail 'disable benötigt FORM_ALLOW_INSECURE_DEV=1' ;;
    *) db_fail 'FORM_DB_TLS muss verify oder disable sein' ;;
  esac
  [[ -z "$DB_TLS_CA_FILE" || -r "$DB_TLS_CA_FILE" ]] || db_fail 'CA-Datei nicht lesbar'
  if [[ -n "$DB_TLS_CA_FILE" && "$DB_TLS_CA_FILE" != /* ]]; then DB_TLS_CA_FILE="$PWD/$DB_TLS_CA_FILE"; fi
  case "$DB_CLIENT_MODE" in docker) command -v docker >/dev/null || db_fail 'Docker fehlt' ;; local) ;; *) db_fail 'DB_CLIENT_MODE muss docker oder local sein' ;; esac
  export FORM_DB_HOST FORM_DB_PORT FORM_DB_USER FORM_DB_NAME FORM_DB_TLS DB_CONNECT_TIMEOUT
}
db_tool() (
  # Subshell keeps MYSQL_PWD and temporary credential-file cleanup out of the caller's traps.
  set -euo pipefail
  tool=$1; shift
  client_args=(--protocol=TCP "--host=$FORM_DB_HOST" "--port=$FORM_DB_PORT" "--user=$FORM_DB_USER")
  # mariadb-dump rejects --connect-timeout (verified against mariadb:12.3); the interactive client accepts it.
  [[ "$tool" == mariadb-dump ]] || client_args+=("--connect-timeout=$DB_CONNECT_TIMEOUT")
  if [[ "$FORM_DB_TLS" == verify ]]; then client_args+=(--ssl --ssl-verify-server-cert)
  else client_args+=(--skip-ssl); fi
  if [[ "$DB_CLIENT_MODE" == local ]]; then
    command -v "$tool" >/dev/null || db_fail "$tool fehlt"
    MYSQL_PWD=${FORM_DB_PASSWORD:-}
    [[ -n "$MYSQL_PWD" ]] || MYSQL_PWD=$(cat "$DB_PASSWORD_INPUT_FILE")
    export MYSQL_PWD
    [[ -z "$DB_TLS_CA_FILE" ]] || client_args+=("--ssl-ca=$DB_TLS_CA_FILE")
    "$tool" "${client_args[@]}" "$@"
  else
    mounts=(); network=()
    password_file=$DB_PASSWORD_INPUT_FILE
    if [[ -n "${FORM_DB_PASSWORD:-}" ]]; then
      password_file=$(mktemp)
      chmod 600 "$password_file"
      trap 'rm -f "$password_file"' EXIT
      printf '%s' "$FORM_DB_PASSWORD" > "$password_file"
    fi
    mounts+=(--mount "type=bind,source=$password_file,target=/run/secrets/db_password,readonly")
    if [[ -n "$DB_TLS_CA_FILE" ]]; then
      mounts+=(--mount "type=bind,source=$DB_TLS_CA_FILE,target=$DB_CLIENT_CA_PATH,readonly")
      client_args+=("--ssl-ca=$DB_CLIENT_CA_PATH")
    fi
    [[ -z "$DB_CLIENT_NETWORK" ]] || network+=(--network "$DB_CLIENT_NETWORK")
    docker run --rm -i --memory "$DB_CLIENT_MEMORY" ${network[@]+"${network[@]}"} "${mounts[@]}" \
      --entrypoint bash "$DB_CLIENT_IMAGE" -euo pipefail -c \
      'export MYSQL_PWD="$(cat /run/secrets/db_password)"; exec "$@"' bash \
      "$tool" "${client_args[@]}" "$@"
  fi
)
db_counts() {
  local database=$1 table escaped tables
  tables=$(db_tool mariadb -N -B -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$database' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME") || return
  [[ -n "$tables" ]] || return 0
  while IFS= read -r table; do
    escaped=${table//\`/\`\`}
    printf '%s\t' "$table"
    # </dev/null: `docker run -i` would otherwise swallow the remaining table list from the here-string.
    db_tool mariadb -N -B -e "SELECT COUNT(*) FROM \`$database\`.\`$escaped\`" </dev/null
  done <<< "$tables"
}
# Recommended server-side max_allowed_packet (bytes): a sealed object of 32 MiB becomes a ~80 MiB hex-blob dump line (docs/BETRIEB.md).
DB_RECOMMENDED_PACKET=268435456
# Prints the server's max_allowed_packet in bytes, or nothing when it cannot be read.
db_packet_limit() {
  local v
  v=$(db_tool mariadb -N -B -e 'SELECT @@max_allowed_packet' </dev/null 2>/dev/null | tr -d '[:space:]') || return 0
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}
# db_require_packet NEEDED_BYTES: abort when the server limit is known and below NEEDED; warn below the recommendation.
db_require_packet() {
  local needed=$1 limit
  limit=$(db_packet_limit)
  if [[ -z "$limit" ]]; then
    echo 'Warnung: max_allowed_packet des DB-Servers nicht lesbar; Mindestwert 256M (docs/BETRIEB.md) selbst prüfen.' >&2; return 0
  fi
  if (( limit < needed )); then
    db_fail "max_allowed_packet des DB-Servers ($((limit / 1048576)) MiB) ist zu klein; benötigt mindestens $(((needed + 1048575) / 1048576)) MiB (Empfehlung 256M). Beispiel: SET GLOBAL max_allowed_packet=268435456 und in der Serverkonfiguration dauerhaft setzen. Es wurde nichts geschrieben."
  fi
  if (( limit < DB_RECOMMENDED_PACKET )); then
    echo "Warnung: max_allowed_packet des DB-Servers ($((limit / 1048576)) MiB) liegt unter der Empfehlung 256M; sehr große versiegelte Objekte (bis 32 MiB, als Hex-Dump ~80 MiB) lassen sich sonst nicht wiederherstellen." >&2
  fi
}
checksum() { openssl dgst -sha256 "$1" | awk '{print $NF}'; }

# Entfernt DEFINER=`u`@`h` aus CREATE-Anweisungen von Triggern/Routinen/Events/Views im Dump (nur in Zeilen, die mit CREATE bzw. /*!NNNNN CREATE*/ beginnen,
# nie in Datenzeilen). Ein Restore-Benutzer ohne SET USER/SUPER-Recht scheitert sonst am ersten Trigger (ERROR 1227); ohne DEFINER gehoeren die Objekte ihm.
strip_definer() { LC_ALL=C sed -E '/^(\/\*![0-9]+ CREATE\*\/ |CREATE )/ s/ ?DEFINER=`[^`]*`@`[^`]*`//'; }
