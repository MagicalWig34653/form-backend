#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shared Swarm/Compose deployment orchestration; env files are parsed, never executed.
set -euo pipefail
fail() { printf 'Fehler: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null || fail "$1 wird benötigt"; }
SECRET_KEYS='FORM_DB_PASSWORD FORM_SERVER_KEY FORM_BOOTSTRAP_PASSWORD'

read_config() {
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" == *=* ]] || fail 'Konfiguration erwartet KEY=VALUE'
    key=${line%%=*}; value=${line#*=}
    [[ "$key" =~ ^[A-Z][A-Z0-9_]+$ ]] || fail 'Ungültiger Variablenname'
    case " $CONFIG_KEYS $SECRET_KEYS " in *" $key "*) ;; *) fail "Unbekannte Variable: $key" ;; esac
    case "$value" in \"*\"|\'*\') value=${value:1:${#value}-2} ;; esac
    # No shell expansion, substitutions or multi-line values. Passwords should come from source files.
    [[ "$value" != *'$'* && "$value" != *'`'* && "$value" != *\\* && "$value" != *$'\n'* ]] || fail "Keine Expansion/Steuerzeichen erlaubt: $key"
    printf -v "$key" '%s' "$value"; export "${key?}"
  done < "$1"
}
# Eingabe-Prüfung je Feld (gleiche Regeln wie validate); Rückgabe 0 = ok, sonst Hinweistext in FIELD_ERR.
field_ok() {
  local key=$1 v=$2; FIELD_ERR=''
  case "$key" in
    STACK) [[ "$v" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || FIELD_ERR='Kleinbuchstaben, Ziffern, - ; beginnt mit Buchstabe' ;;
    FORM_ADMIN_ORIGIN) [[ "$v" =~ ^https://[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?$ ]] || FIELD_ERR='Form https://host[:port], ohne Pfad' ;;
    FORM_RP_ID) [[ "$v" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || FIELD_ERR='Nur Hostname, z. B. admin.example.org' ;;
    FORM_DB_HOST) [[ -n "$v" && "$v" != -* && "$v" != *[[:space:]]* ]] || FIELD_ERR='Host oder IP, ohne Leerzeichen' ;;
    FORM_DB_PORT|FORM_REPLICAS|FORM_PINNED_REPLICAS) [[ "$v" =~ ^[0-9]{1,5}$ ]] || FIELD_ERR='Zahl erwartet' ;;
    FORM_DB_USER) [[ "$v" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$ ]] || FIELD_ERR='Buchstabe am Anfang, dann Buchstaben, Ziffern, _ . -' ;;
    FORM_DB_NAME) [[ "$v" =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]] || FIELD_ERR='Buchstabe am Anfang, dann Buchstaben, Ziffern, _' ;;
    FORM_DB_TLS) [[ "$v" == verify || "$v" == disable ]] || FIELD_ERR='verify oder disable' ;;
    FORM_IMAGE_TAG) [[ "$v" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$ ]] || FIELD_ERR='Gültiger Image-Tag' ;;
    PUBLISH_MODE) [[ "$v" == ingress || "$v" == host ]] || FIELD_ERR='ingress oder host' ;;
  esac
  [[ -z "$FIELD_ERR" ]]
}
# Dialog (whiptail/dialog) nur mit Terminal; sonst einfache Zeilenabfrage.
dialog_tool() {
  [[ -t 0 && -t 1 && -z "${FORM_PLAIN_PROMPT:-}" ]] || return 1
  command -v whiptail 2>/dev/null || command -v dialog 2>/dev/null
}
ask() {
  local key=$1 label=$2 default=${3-${!1}} answer tool
  tool=$(dialog_tool || true)
  while :; do
    if [[ -n "$tool" ]]; then
      answer=$("$tool" --backtitle 'form-backend: Einrichtung' --title "$key" --inputbox "$label${FIELD_ERR:+

Eingabe ungültig: $FIELD_ERR}" 13 72 "$default" 3>&1 1>&2 2>&3) || fail 'Eingabe abgebrochen'
    else
      printf '%s [%s]: ' "$label" "$default"
      IFS= read -r answer || fail 'Eingabe abgebrochen'
      answer=${answer:-$default}
    fi
    if [[ "$answer" == - ]] || field_ok "$key" "$answer" || { [[ -z "$answer" ]] && ! field_ok "$key" x; }; then break; fi
    [[ -n "$tool" ]] || printf 'Ungültig: %s\n' "$FIELD_ERR" >&2
    default=$answer
  done
  FIELD_ERR=''
  printf -v "$key" '%s' "$answer"
}
ask_optional() {
  ask "$1" "$2 (- löscht den Wert)"
  if [[ "${!1}" == - ]]; then printf -v "$1" '%s' ''; fi
}
absolute_path() {
  [[ "$1" == /* ]] && printf '%s' "$1" || printf '%s/%s' "$(dirname "$ENV_FILE")" "$1"
}
validate() {
  local key value host port_keys
  [[ "$STACK" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || fail 'Ungültiger Stack-/Projektname'
  [[ "$FORM_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]+$ ]] || fail 'Ungültige Image-Referenz'
  [[ "$FORM_ADMIN_ORIGIN" =~ ^https://([a-z0-9][a-z0-9.-]*)(:[0-9]{1,5})?$ ]] || fail 'Origin muss https://host[:port] ohne Pfad sein'
  host=${BASH_REMATCH[1]}
  [[ "$FORM_RP_ID" =~ ^[a-z0-9][a-z0-9.-]*$ && ( "$host" == "$FORM_RP_ID" || "$host" == *."$FORM_RP_ID" ) ]] || fail 'RP-ID muss zum Origin-Host passen'
  [[ -n "$FORM_DB_HOST" && "$FORM_DB_HOST" != -* ]] || fail 'Externer DB-Host fehlt'
  for key in FORM_DB_NAME FORM_DB_USER; do
    value=${!key}; field_ok "$key" "$value" || fail "Ungültiges $key: $FIELD_ERR"
  done
  for key in FORM_HTTP_PORT FORM_PUBLIC_PORT FORM_INTERNAL_PORT; do
    local file_key="${key}_FILE"
    [[ -z "${!file_key:-}" ]] || fail "$file_key wird nicht unterstützt; Port direkt setzen"
  done
  FORM_INTERNAL_PORT=${FORM_INTERNAL_PORT:-$FORM_HTTP_PORT}
  export FORM_INTERNAL_PORT
  [[ "$FORM_PUBLIC_DASHBOARD" == 0 || "$FORM_PUBLIC_DASHBOARD" == 1 ]] || fail 'FORM_PUBLIC_DASHBOARD muss 0 oder 1 sein'
  [[ "$FORM_PUBLIC_DASHBOARD" != 1 || -n "$FORM_PUBLIC_DASHBOARD_HOSTS" ]] || fail 'FORM_PUBLIC_DASHBOARD_HOSTS fehlt'
  # shellcheck disable=SC2153 # Assigned by the parsed ENV template.
  [[ "$FORM_PUBLIC_PORT" != "$FORM_INTERNAL_PORT" ]] || fail 'Listener benötigen unterschiedliche Ports'
  port_keys='FORM_DB_PORT FORM_HTTP_PORT FORM_PUBLIC_PORT FORM_INTERNAL_PORT FORM_PUBLIC_PUBLISH_PORT'
  if [[ "$MODE" == swarm ]]; then
    port_keys+=' FORM_PUBLISH_PORT FORM_PINNED_PUBLISH_PORT FORM_PINNED_PUBLIC_PUBLISH_PORT'
  else port_keys+=' PUBLISHED_PORT'; fi
  for key in $port_keys; do
    value=${!key}
    if [[ ( "$key" == *PUBLISH_PORT || "$key" == PUBLISHED_PORT ) && -z "$value" ]]; then continue; fi
    if [[ ! "$value" =~ ^[0-9]{1,5}$ ]]; then fail "Ungültiger Port: $key"; fi
    (( 10#$value >= 1 && 10#$value <= 65535 )) || fail "Ungültiger Port: $key"
  done
  case "$FORM_DB_TLS" in
    verify) ;;
    disable) [[ "$FORM_ALLOW_INSECURE_DEV" == 1 ]] || fail 'disable benötigt FORM_ALLOW_INSECURE_DEV=1 (auch unsichere Mail-/Deploy-Ziele erlaubt)' ;;
    *) fail 'FORM_DB_TLS muss verify oder disable sein' ;;
  esac
  for key in APP_UID APP_GID FORM_REPLICAS WAIT_SECONDS HEALTH_RETRIES DB_CONNECT_TIMEOUT; do
    value=${!key}; [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] || fail "Ungültige positive Zahl: $key"
  done
  for key in UPDATE_PARALLELISM ROLLBACK_PARALLELISM; do
    value=${!key}; [[ "$value" =~ ^[0-9]{1,3}$ ]] || fail "Ungültige Parallelität: $key"
  done
  for key in FORM_DB_PASSWORD_FILE FORM_SERVER_KEY_FILE FORM_BOOTSTRAP_PASSWORD_FILE ENTRYPOINT_PATH HEALTHCHECK_PATH FORM_APP_BINARY DB_CLIENT_CA_PATH; do
    value=${!key}; [[ "$value" == /* && "$value" != *[[:space:]]* ]] || fail "$key benötigt einen absoluten Containerpfad ohne Leerzeichen"
  done
  for key in DB_PASSWORD_SECRET SERVER_KEY_SECRET BOOTSTRAP_PASSWORD_SECRET NETWORK_NAME; do
    value=${!key}; [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || fail "Ungültiger Name: $key"
  done
  [[ "$DB_PASSWORD_SECRET" != "$SERVER_KEY_SECRET" && "$DB_PASSWORD_SECRET" != "$BOOTSTRAP_PASSWORD_SECRET" && "$SERVER_KEY_SECRET" != "$BOOTSTRAP_PASSWORD_SECRET" ]] || fail 'Secret-Namen müssen verschieden sein'
  if [[ "$MODE" == swarm ]]; then
    validate_placement
    validate_publication
    [[ "$BIND_ADDR" == 0.0.0.0 ]] || fail 'Swarm unterstützt keine Host-IP-Bindung; BIND_ADDR=0.0.0.0 setzen und Firewall auf Proxy begrenzen'
    [[ "$NETWORK_DRIVER" == overlay ]] || fail 'Swarm benötigt ein overlay-Netz'
    [[ "$PUBLISH_MODE" == host || "$PUBLISH_MODE" == ingress ]] || fail 'PUBLISH_MODE muss host oder ingress sein'
  else
    if [[ -n "$PUBLISHED_PORT" && -n "$FORM_PUBLIC_PUBLISH_PORT" ]]; then
      (( 10#$PUBLISHED_PORT != 10#$FORM_PUBLIC_PUBLISH_PORT )) || fail 'Veröffentlichungsports müssen verschieden sein'
    fi
    [[ "$BIND_ADDR" =~ ^[a-zA-Z0-9.:_-]+$ ]] || fail 'Ungültige Bind-Adresse'
    [[ "$FORM_REPLICAS" == 1 ]] || fail 'Compose mit festem Hostport unterstützt hier genau eine App-Replika'
    [[ "$NETWORK_DRIVER" == bridge ]] || fail 'Compose benötigt hier ein bridge-Netz'
  fi
}
# Restrict rendered scalars to safe Swarm expressions; never interpret ENV as YAML/code.
validate_placement() {
  local item rest key pattern
  APP_CONSTRAINTS=(); APP_PREFERENCES=(); EXCLUDE_ARGS=()
  pattern='^[a-zA-Z0-9_.-]+[[:space:]]*(==|!=)[[:space:]]*[a-zA-Z0-9_./:@-]+$'
  for key in FORM_PLACEMENT_CONSTRAINTS FORM_PLACEMENT_PREFERENCES; do
    rest=${!key}
    [[ -z "$rest" || ( "$rest" != ,* && "$rest" != *, ) ]] || fail "Leerer Listeneintrag: $key"
    while [[ -n "$rest" ]]; do
      item=${rest%%,*}
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      if [[ "$key" == FORM_PLACEMENT_CONSTRAINTS ]]; then
        [[ "$item" =~ $pattern ]] || fail "Ungültige Constraint: $item"
        APP_CONSTRAINTS+=("$item")
      else
        [[ "$item" =~ ^spread=(node|engine)\.labels\.[a-zA-Z0-9_.-]+$ ]] || fail "Ungültige Präferenz: $item"
        APP_PREFERENCES+=("${item#spread=}")
      fi
      [[ "$rest" == *,* ]] || break
      rest=${rest#*,}
    done
  done
  [[ -z "$FORM_EXCLUDE_LABEL" || "$FORM_EXCLUDE_LABEL" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'Ungültiges Ausschluss-Label'
  if [[ -n "$FORM_EXCLUDE_LABEL" ]]; then
    APP_CONSTRAINTS+=("node.labels.$FORM_EXCLUDE_LABEL!=true")
    EXCLUDE_ARGS=(--constraint "node.labels.$FORM_EXCLUDE_LABEL!=true")
  fi
  [[ "$FORM_PINNED_REPLICAS" =~ ^[1-9][0-9]{0,5}$ ]] || fail 'FORM_PINNED_REPLICAS muss positiv sein'
  FORM_PINNED_EFFECTIVE_REPLICAS=0
  FORM_PINNED_CONSTRAINT='node.hostname==__form_pinning_disabled__'
  if [[ -n "$FORM_PINNED_NODE" ]]; then
    [[ "$FORM_PINNED_NODE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'Ungültiger Knotenname/Node-ID'
    FORM_PINNED_EFFECTIVE_REPLICAS=$FORM_PINNED_REPLICAS
    if [[ "$FORM_PINNED_NODE" =~ ^[a-z0-9]{25}$ ]]; then
      FORM_PINNED_CONSTRAINT="node.id==$FORM_PINNED_NODE"
    else FORM_PINNED_CONSTRAINT="node.hostname==$FORM_PINNED_NODE"; fi
  fi
  export FORM_PINNED_EFFECTIVE_REPLICAS FORM_PINNED_CONSTRAINT
}
validate_publication() {
  [[ -z "$FORM_PUBLISH_BIND" || "$FORM_PUBLISH_BIND" == 0.0.0.0 ]] || fail 'Swarm unterstützt FORM_PUBLISH_BIND nur leer/0.0.0.0; Zugriff per Firewall begrenzen'
  if [[ -n "$FORM_PUBLISH_PORT" && -n "$FORM_PINNED_PUBLISH_PORT" ]]; then
    (( 10#$FORM_PUBLISH_PORT != 10#$FORM_PINNED_PUBLISH_PORT )) || fail 'App und app-pinned benötigen unterschiedliche Veröffentlichungsports'
  fi
  local seen=' ' published
  for published in "$FORM_PUBLISH_PORT" "$FORM_PUBLIC_PUBLISH_PORT" "$FORM_PINNED_PUBLISH_PORT" "$FORM_PINNED_PUBLIC_PUBLISH_PORT"; do
    [[ -n "$published" ]] || continue
    [[ "$seen" != *" $((10#$published)) "* ]] || fail 'Veröffentlichungsports müssen verschieden sein'
    seen+="$((10#$published)) "
  done
  FORM_APP_ENDPOINT_MODE=dnsrr; FORM_PINNED_ENDPOINT_MODE=dnsrr
  FORM_PINNED_EFFECTIVE_PORT=''
  [[ -z "$FORM_PINNED_NODE" ]] || FORM_PINNED_EFFECTIVE_PORT=$FORM_PINNED_PUBLISH_PORT
  if [[ "$PUBLISH_MODE" == ingress ]]; then
    [[ -z "$FORM_PUBLISH_PORT$FORM_PUBLIC_PUBLISH_PORT" ]] || FORM_APP_ENDPOINT_MODE=vip
    [[ -z "$FORM_PINNED_EFFECTIVE_PORT" && ( -z "$FORM_PINNED_NODE" || -z "$FORM_PINNED_PUBLIC_PUBLISH_PORT" ) ]] || FORM_PINNED_ENDPOINT_MODE=vip
  fi
  export FORM_APP_ENDPOINT_MODE FORM_PINNED_ENDPOINT_MODE
}
render_port() {
  local internal=$1 public=$2
  if [[ -z "$internal$public" ]]; then printf '    ports: []\n'; return; fi
  printf '    ports:\n'
  if [[ -n "$internal" ]]; then printf '      - { target: %s, published: %s, protocol: tcp, mode: "%s" }\n' "$((10#$FORM_INTERNAL_PORT))" "$((10#$internal))" "$PUBLISH_MODE"; fi
  if [[ -n "$public" ]]; then printf '      - { target: %s, published: %s, protocol: tcp, mode: "%s" }\n' "$((10#$FORM_PUBLIC_PORT))" "$((10#$public))" "$PUBLISH_MODE"; fi
}
render_compose() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == *'# FORM_COMPOSE_PORTS' ]]; then
      if [[ -z "$PUBLISHED_PORT$FORM_PUBLIC_PUBLISH_PORT" ]]; then printf '    ports: []\n'; continue; fi
      printf '    ports:\n'
      [[ -z "$PUBLISHED_PORT" ]] || printf '      - "%s:%s:%s"\n' "$BIND_ADDR" "$PUBLISHED_PORT" "$FORM_INTERNAL_PORT"
      [[ -z "$FORM_PUBLIC_PUBLISH_PORT" ]] || printf '      - "%s:%s:%s"\n' "$BIND_ADDR" "$FORM_PUBLIC_PUBLISH_PORT" "$FORM_PUBLIC_PORT"
    else printf '%s\n' "$line"; fi
  done < "$BASE/compose.yaml"
}
# Keep anchors in the template; render only marked ports and placement lists.
render_swarm() {
  local line item
  while IFS= read -r line; do
    case "$line" in
      *'# FORM_APP_PORTS') render_port "$FORM_PUBLISH_PORT" "$FORM_PUBLIC_PUBLISH_PORT" ;;
      *'# FORM_PINNED_PORTS') render_port "$FORM_PINNED_EFFECTIVE_PORT" "${FORM_PINNED_NODE:+$FORM_PINNED_PUBLIC_PUBLISH_PORT}" ;;
      *'# FORM_APP_CONSTRAINTS')
        if (( ${#APP_CONSTRAINTS[@]} )); then
          printf '        constraints:\n'
          for item in "${APP_CONSTRAINTS[@]}"; do printf '          - "%s"\n' "$item"; done
        else printf '        constraints: []\n'; fi ;;
      *'# FORM_APP_PREFERENCES')
        if (( ${#APP_PREFERENCES[@]} )); then
          printf '        preferences:\n'
          for item in "${APP_PREFERENCES[@]}"; do printf '          - spread: "%s"\n' "$item"; done
        else printf '        preferences: []\n'; fi ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$BASE/stack.yaml"
}
parse_args() {
  ADMIN_CMD=''; ADMIN_USER=admin; DRY=0; NONINTERACTIVE=0; IMAGE_ARG=''; TAG_ARG=''; KEY_ARG=''; PASSWORD_ARG=''
  ENV_FILE="$BASE/stack.env"; [[ "$MODE" != compose ]] || ENV_FILE="$BASE/.env"
  while (( $# )); do
    case "$1" in
      --dry-run) DRY=1; shift ;;
      --non-interactive) NONINTERACTIVE=1; shift ;;
      --env-file) ENV_FILE=${2:?Pfad fehlt}; shift 2 ;;
      --image) IMAGE_ARG=${2:?Image fehlt}; shift 2 ;;
      --tag) TAG_ARG=${2:?Tag fehlt}; shift 2 ;;
      --server-key-file) KEY_ARG=${2:?Pfad fehlt}; shift 2 ;;
      --db-password-file) PASSWORD_ARG=${2:?Pfad fehlt}; shift 2 ;;
      --help|-h)
        printf 'Aufruf: %s [--env-file DATEI] [--image IMAGE | --tag TAG] [--dry-run]\n' "$0"
        say 'Setup: interaktiv oder --non-interactive; --db-password-file DATEI, --server-key-file DATEI optional.'
        say 'Update: neues Image über --image/--tag oder FORM_IMAGE/FORM_IMAGE_TAG in der Umgebung wählen.'
        say 'Datenbank, Benutzer und TLS-Proxy müssen bereits existieren. Setup führt nur SELECT 1 aus.'
        say 'Trockenlauf: keine Docker-Aufrufe, Dateiänderungen oder Secret-Erzeugung.'
        return 10 ;;
      bootstrap-admin|enroll-passkey) [[ "$ACTION" == admin ]] || fail "Unbekannte Option: $1"; ADMIN_CMD=$1; ADMIN_USER=${2:-admin}; shift 2 2>/dev/null || shift ;;
      *) fail "Unbekannte Option: $1" ;;
    esac
  done
  [[ "$ACTION" != admin || -n "${ADMIN_CMD:-}" ]] || fail 'Aufruf: admin.sh bootstrap-admin|enroll-passkey [BENUTZER]'
  [[ -z "$TAG_ARG" || -z "$IMAGE_ARG" ]] || fail '--tag und --image sind Alternativen'
  [[ "$ENV_FILE" == /* ]] || ENV_FILE="$PWD/$ENV_FILE"
  [[ -d "$(dirname "$ENV_FILE")" ]] || fail 'Env-Verzeichnis fehlt'
}
initialize() {
  local rc=0 key i
  parse_args "$@" || rc=$?
  [[ "$rc" != 10 ]] || return 10
  TEMPLATE="$BASE/stack.env.example"; [[ "$MODE" != compose ]] || TEMPLATE="$BASE/.env.example"
  CONFIG_KEYS=$(sed -n 's/^\(# \)\{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\2/p' "$TEMPLATE" | tr '\n' ' ')
  # Commented secret aliases remain process-only and must never enter persisted config.
  local public_keys=''
  for key in $CONFIG_KEYS; do
    case " $SECRET_KEYS " in *" $key "*) ;; *) public_keys+=" $key" ;; esac
  done
  CONFIG_KEYS=$public_keys
  # Process ENV > saved file > documented defaults; CLI image/source flags win afterwards.
  ENV_KEYS=(__SENTINEL); ENV_VALUES=('')
  for key in $CONFIG_KEYS $SECRET_KEYS; do
    if [[ -n "${!key+x}" ]]; then ENV_KEYS+=("$key"); ENV_VALUES+=("${!key}"); fi
  done
  read_config "$TEMPLATE"
  [[ ! -f "$ENV_FILE" ]] || read_config "$ENV_FILE"
  for ((i=1; i<${#ENV_KEYS[@]}; i++)); do printf -v "${ENV_KEYS[i]}" '%s' "${ENV_VALUES[i]}"; done
  if [[ "$ACTION" == setup && "$NONINTERACTIVE" == 0 && ! -f "$ENV_FILE" ]]; then
    ask STACK 'Stack-/Projektname'
    ask FORM_ADMIN_ORIGIN 'Öffentliche HTTPS-Origin'
    local rp_default=${FORM_ADMIN_ORIGIN#https://}
    ask FORM_RP_ID 'Passkey RP-ID' "${rp_default%%:*}"
    ask FORM_DB_HOST 'Externer MariaDB-Host (bereits bereitgestellt)'
    ask FORM_DB_PORT 'MariaDB-Port'
    ask FORM_DB_USER 'Vorhandener DB-Benutzer'
    ask FORM_DB_NAME 'Vorhandene Datenbank'
    ask FORM_DB_TLS 'DB-TLS (verify/disable)'
    [[ "$FORM_DB_TLS" != disable ]] || ask FORM_ALLOW_INSECURE_DEV 'Unverschlüsselte DB braucht Entwicklungsfreigabe (1 = ja; erlaubt auch unsichere Mail-/Deploy-Ziele)' 1
    ask FORM_IMAGE_TAG 'Image-Tag'
    if [[ "$MODE" == swarm ]]; then
      ask FORM_REPLICAS 'App-Replikate (zusätzlich zu app-pinned)'
    fi
  fi
  if [[ "$MODE" == swarm && "$NONINTERACTIVE" == 0 ]]; then
    ask_optional FORM_PLACEMENT_CONSTRAINTS 'App-Constraints (kommagetrennt; leer = keine)'
    ask_optional FORM_PLACEMENT_PREFERENCES 'App-Präferenzen (z.B. spread=node.labels.zone)'
    ask_optional FORM_PINNED_NODE 'Fester Knoten (Hostname/Node-ID; leer = aus)'
    ask FORM_PINNED_REPLICAS 'Zusätzliche Replikate auf festem Knoten'
    ask_optional FORM_EXCLUDE_LABEL 'Ausgeschlossenes Node-Label (z.B. reserved; leer = aus)'
    ask_optional FORM_PUBLIC_PUBLISH_PORT 'Öffentlicher Listener: Veröffentlichungsport (leer = keiner)'
    ask_optional FORM_PUBLISH_PORT 'Veröffentlichungsport app (leer = keiner)'
    ask_optional FORM_PINNED_PUBLISH_PORT 'Veröffentlichungsport app-pinned (anderer Port; leer = keiner)'
    ask PUBLISH_MODE 'Veröffentlichungsmodus (ingress/host)'
    ask_optional FORM_PUBLISH_BIND 'Swarm-Bind (nur leer/0.0.0.0; keine einzelne Host-IP)'
  fi
  if [[ -n "$TAG_ARG" ]]; then FORM_IMAGE_TAG=$TAG_ARG; FORM_IMAGE=''; fi
  # An explicit process tag deliberately replaces a saved digest.
  if [[ -n "${FORM_IMAGE_TAG+x}" ]]; then
    local explicit_tag=0 explicit_image=0
    for key in "${ENV_KEYS[@]}"; do
      [[ "$key" != FORM_IMAGE_TAG ]] || explicit_tag=1
      [[ "$key" != FORM_IMAGE ]] || explicit_image=1
    done
    [[ "$explicit_tag" != 1 || "$explicit_image" == 1 ]] || FORM_IMAGE=''
  fi
  [[ -z "$IMAGE_ARG" ]] || FORM_IMAGE=$IMAGE_ARG
  : "${FORM_IMAGE:=${FORM_IMAGE_REPOSITORY}:${FORM_IMAGE_TAG}}"
  : "${NETWORK_NAME:=${STACK}_backend}" "${DB_PASSWORD_SECRET:=${STACK}_db_password}" "${SERVER_KEY_SECRET:=${STACK}_server_key}" "${BOOTSTRAP_PASSWORD_SECRET:=${STACK}_bootstrap_password}"
  [[ -z "$KEY_ARG" ]] || SERVER_KEY_SOURCE_FILE=$KEY_ARG
  [[ -z "$PASSWORD_ARG" ]] || DB_PASSWORD_SOURCE_FILE=$PASSWORD_ARG
  EXPLICIT_DB_SOURCE=0; EXPLICIT_KEY_SOURCE=0; EXPLICIT_BOOTSTRAP_SOURCE=0
  [[ -z "$DB_PASSWORD_SOURCE_FILE" ]] || EXPLICIT_DB_SOURCE=1
  [[ -z "$SERVER_KEY_SOURCE_FILE" ]] || EXPLICIT_KEY_SOURCE=1
  [[ -z "$BOOTSTRAP_PASSWORD_SOURCE_FILE" ]] || EXPLICIT_BOOTSTRAP_SOURCE=1
  SECRET_DIR="$BASE/secrets"
  : "${DB_PASSWORD_SOURCE_FILE:=$SECRET_DIR/db_password}" "${SERVER_KEY_SOURCE_FILE:=$SECRET_DIR/server_key}" "${BOOTSTRAP_PASSWORD_SOURCE_FILE:=$SECRET_DIR/bootstrap_password}"
  for key in DB_PASSWORD_SOURCE_FILE SERVER_KEY_SOURCE_FILE BOOTSTRAP_PASSWORD_SOURCE_FILE DB_TLS_CA_FILE; do
    [[ -z "${!key}" ]] || printf -v "$key" '%s' "$(absolute_path "${!key}")"
  done
  validate
  [[ "$ACTION" != update && "$ACTION" != admin || -f "$ENV_FILE" ]] || fail 'Zuerst Setup ausführen'
  for key in $CONFIG_KEYS; do [[ -z "${!key+x}" ]] || export "${key?}"; done
  CONFIG_REV=$(cat "$BASE/../docker-entrypoint.sh" "$BASE/../swarm/healthcheck.sh" | cksum | awk '{print $1}')
  export CONFIG_REV
  ENTRY_CONFIG="${STACK}_entry_${CONFIG_REV}"; HEALTH_CONFIG="${STACK}_health_${CONFIG_REV}"
}
save_config() {
  local tmp line key value
  [[ ! -L "$ENV_FILE" ]] || fail 'Env-Datei darf kein Symlink sein'
  tmp=$(mktemp "${ENV_FILE}.XXXXXX"); chmod 600 "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^#[[:space:]]([A-Z][A-Z0-9_]+)= ]]; then
      key=${BASH_REMATCH[1]}
      case " $SECRET_KEYS " in
        *" $key "*) ;;
        *) if [[ -n "${!key+x}" ]]; then line="$key="; fi ;;
      esac
    fi
    case "$line" in ''|'#'*) printf '%s\n' "$line" ;; *)
      key=${line%%=*}; value=${!key}
      # Preserve JSON lists using dotenv single quotes; the parser does not unescape values.
      if [[ "$value" == *'"'* ]]; then
        [[ "$value" != *"'"* ]] || fail "Gemischte Quotes im Wert nicht unterstützt: $key"
        printf "%s='%s'\n" "$key" "$value"
      else
        printf '%s="%s"\n' "$key" "$value"
      fi ;;
    esac
  done < "$TEMPLATE" > "$tmp"
  if [[ -f "$ENV_FILE" ]]; then cp -p "$ENV_FILE" "${ENV_FILE}.bak"; chmod 600 "${ENV_FILE}.bak"; fi
  mv "$tmp" "$ENV_FILE"
}
compose() { render_compose | docker compose --project-directory "$BASE" --project-name "$STACK" --env-file "$ENV_FILE" -f - "$@"; }
plan() {
  say "Trockenlauf ($MODE/$ACTION): $STACK; Image $FORM_IMAGE"
  # FORM_DB_PORT is initialized through the parsed template.
  # shellcheck disable=SC2153
  say "Externe DB: $FORM_DB_USER@$FORM_DB_HOST:$FORM_DB_PORT/$FORM_DB_NAME; TLS=$FORM_DB_TLS. Keine DB-/Benutzeranlage."
  if [[ "$MODE" == swarm ]]; then
    say "Netz: $NETWORK_NAME ($NETWORK_DRIVER); Overlay-Proxy-Ziel: ${STACK}-public:$FORM_PUBLIC_PORT / ${STACK}-internal:$FORM_INTERNAL_PORT."
    say "Veröffentlichung: app=${FORM_PUBLISH_PORT:-aus}; app-pinned=${FORM_PINNED_EFFECTIVE_PORT:-aus} (konfiguriert: ${FORM_PINNED_PUBLISH_PORT:-aus}); Modus=$PUBLISH_MODE; alle Host-IPs; öffentlich app=${FORM_PUBLIC_PUBLISH_PORT:-aus}, app-pinned=${FORM_PINNED_NODE:+$FORM_PINNED_PUBLIC_PUBLISH_PORT}."
    say "Externer Proxy: veröffentlichte Ports als getrennte Upstreams; Routing-Mesh verteilt nur im jeweiligen Dienst."
    say "app: $FORM_REPLICAS Replikate; Constraints=${FORM_PLACEMENT_CONSTRAINTS:-keine}; Präferenzen=${FORM_PLACEMENT_PREFERENCES:-keine}."
    say "Ausschluss: ${FORM_EXCLUDE_LABEL:-aus} (app, DB-Prüfung, Migration; app-pinned ausgenommen)."
    say "app-pinned: $FORM_PINNED_EFFECTIVE_REPLICAS Replikate; Knoten=${FORM_PINNED_NODE:-aus}; Constraint=$FORM_PINNED_CONSTRAINT."
    say "Gesamt: $((FORM_REPLICAS + FORM_PINNED_EFFECTIVE_REPLICAS)) Replikate (app + app-pinned)."
  else
    say "Netz: $NETWORK_NAME ($NETWORK_DRIVER); HTTP: $BIND_ADDR:${PUBLISHED_PORT:-aus} -> $FORM_INTERNAL_PORT; öffentlich ${FORM_PUBLIC_PUBLISH_PORT:-aus} -> $FORM_PUBLIC_PORT; externer TLS-Proxy."
  fi
  say "Secret-Namen: $DB_PASSWORD_SECRET, $SERVER_KEY_SECRET, $BOOTSTRAP_PASSWORD_SECRET (optional). Keine Werte werden ausgegeben."
  say "Plan: Sperre; neue Secrets; Netz prüfen; Image-Digest fixieren; DB-Client SELECT 1; Migration einmal mit neuem Image; dann App-Rollout und /ready."
  say "Swarm-Update: parallelism=$UPDATE_PARALLELISM monitor=$UPDATE_MONITOR delay=$UPDATE_DELAY order=$UPDATE_ORDER."
  say "Env-Datei $ENV_FILE: 0600, keine Secret-Werte. Rollback setzt kein Schema zurück."
}
cleanup_lock() {
  if [[ "${UNLOCK_SAFE:-0}" == 1 ]]; then
    if [[ "$MODE" == swarm ]]; then docker config rm "$LOCK_NAME" >/dev/null || true
    else rmdir "$LOCK_NAME" || true; fi
  else printf 'Sperre bleibt erhalten: %s. Migration/Rollout vor Wiederholung prüfen (BETRIEB.md).\n' "$LOCK_NAME" >&2; fi
}
acquire_lock() {
  UNLOCK_SAFE=1
  if [[ "$MODE" == swarm ]]; then
    [[ "$(docker info --format '{{.Swarm.ControlAvailable}}')" == true ]] || fail 'Aktiver Swarm-Manager erforderlich'
    LOCK_NAME="${STACK}_deployment_lock"
    printf 'deployment\n' | docker config create "$LOCK_NAME" - >/dev/null || fail 'Deploy-Sperre belegt'
  else LOCK_NAME="${ENV_FILE}.deploy-lock"; mkdir "$LOCK_NAME" || fail 'Deploy-Sperre belegt'; fi
  trap cleanup_lock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
prepare_secrets() {
  local kind path name value var explicit
  [[ "$MODE" != compose || "$EUID" == 0 ]] || fail 'Compose-Setup als root ausführen (lokale Secret-Dateien benötigen App-UID)'
  mkdir -p "$SECRET_DIR"; chmod 700 "$SECRET_DIR"
  for kind in db_password server_key bootstrap_password; do
    case "$kind" in
      db_password) path=$DB_PASSWORD_SOURCE_FILE; name=$DB_PASSWORD_SECRET; var=FORM_DB_PASSWORD; explicit=$EXPLICIT_DB_SOURCE ;;
      server_key) path=$SERVER_KEY_SOURCE_FILE; name=$SERVER_KEY_SECRET; var=FORM_SERVER_KEY; explicit=$EXPLICIT_KEY_SOURCE ;;
      bootstrap_password) path=$BOOTSTRAP_PASSWORD_SOURCE_FILE; name=$BOOTSTRAP_PASSWORD_SECRET; var=FORM_BOOTSTRAP_PASSWORD; explicit=$EXPLICIT_BOOTSTRAP_SOURCE ;;
    esac
    if [[ "$MODE" == swarm ]] && docker secret inspect "$name" >/dev/null 2>&1; then
      say "Secret unverändert: $name (Schlüsselbackup separat sicherstellen)"; continue
    fi
    [[ ! -L "$path" ]] || fail 'Secret-Datei darf kein Symlink sein'
    if [[ ! -e "$path" ]]; then
      [[ "$explicit" == 0 || -n "${!var:-}" ]] || fail "Explizite Secret-Quelldatei fehlt: $path"
      [[ -d "$(dirname "$path")" ]] || fail "Quellverzeichnis fehlt: $(dirname "$path")"
      value=${!var:-}
      if [[ -z "$value" ]]; then
        case "$kind" in
          db_password)
            [[ "$NONINTERACTIVE" == 0 ]] || fail 'Vorhandenes DB-Passwort per --db-password-file oder FORM_DB_PASSWORD bereitstellen'
            printf 'Passwort des bestehenden DB-Benutzers (verdeckt): '; IFS= read -rs value || fail 'Eingabe abgebrochen'; printf '\n'
            [[ -n "$value" ]] || fail 'DB-Passwort darf nicht leer sein' ;;
          server_key) value=$(openssl rand -hex 32) ;;
          bootstrap_password) value=FORM_OPTIONAL_UNSET ;;
        esac
      fi
      ( set -o noclobber; printf '%s\n' "$value" > "$path" )
    fi
    [[ -s "$path" ]] || fail "Leere Secret-Datei: $path"
    if [[ "$kind" == server_key ]]; then
      value=$(cat "$path"); [[ "$value" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Server-Key muss 64 Hexzeichen enthalten'
    fi
    chmod 400 "$path"
    if [[ "$MODE" == swarm ]]; then docker secret create "$name" "$path" >/dev/null
    else chown "$APP_UID:$APP_GID" "$path"; fi
  done
  # Never pass plaintext secrets to child Docker commands; only mounted secret files.
  unset FORM_DB_PASSWORD FORM_SERVER_KEY FORM_BOOTSTRAP_PASSWORD
}
ensure_network() {
  local driver
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    driver=$(docker network inspect "$NETWORK_NAME" --format '{{.Driver}}')
    [[ "$driver" == "$NETWORK_DRIVER" ]] || fail "Netz $NETWORK_NAME hat falschen Treiber: $driver"
  else docker network create --driver "$NETWORK_DRIVER" --attachable "$NETWORK_NAME" >/dev/null; fi
}
ensure_configs() {
  docker config inspect "$ENTRY_CONFIG" >/dev/null 2>&1 || docker config create "$ENTRY_CONFIG" "$BASE/../docker-entrypoint.sh" >/dev/null
  docker config inspect "$HEALTH_CONFIG" >/dev/null 2>&1 || docker config create "$HEALTH_CONFIG" "$BASE/healthcheck.sh" >/dev/null
}
wait_job() {
  local service=$1 end=$((SECONDS + WAIT_SECONDS)) task state code
  while (( SECONDS < end )); do
    task=$(docker service ps -q --no-trunc "$service" | head -n 1)
    if [[ -n "$task" ]]; then
      state=$(docker inspect --format '{{.Status.State}}' "$task")
      case "$state" in
        complete) code=$(docker inspect --format '{{.Status.ContainerStatus.ExitCode}}' "$task"); [[ "$code" == 0 ]] || fail "Job $service: Exitcode $code"; return ;;
        failed|rejected|orphaned|shutdown) fail "Job $service: $state; Task prüfen" ;;
      esac
    fi
    sleep 2
  done
  fail "Job $service: Timeout; Task prüfen"
}
# The same external-client helper is used by setup, backup and restore.
check_db() {
  if [[ "$MODE" == swarm ]]; then
    local ca_config ca_rev
    ca_args=()
    if [[ -n "$DB_TLS_CA_FILE" ]]; then
      [[ -r "$DB_TLS_CA_FILE" ]] || fail 'DB_TLS_CA_FILE nicht lesbar'
      ca_rev=$(cksum < "$DB_TLS_CA_FILE" | awk '{print $1}')
      ca_config="${STACK}_dbca_${ca_rev}"
      docker config inspect "$ca_config" >/dev/null 2>&1 || docker config create "$ca_config" "$DB_TLS_CA_FILE" >/dev/null
      ca_args+=(--config "source=$ca_config,target=$DB_CLIENT_CA_PATH" --env "DB_CLIENT_CA_FILE=$DB_CLIENT_CA_PATH")
    fi
    docker service inspect "${STACK}_dbcheck" >/dev/null 2>&1 && fail 'Alter DB-Prüfservice vorhanden; zuerst Zustand prüfen und gezielt entfernen'
    docker service create --quiet --with-registry-auth --name "${STACK}_dbcheck" --restart-condition none --limit-memory "$DB_CLIENT_MEMORY" \
      ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"} ${ca_args[@]+"${ca_args[@]}"} --network "$NETWORK_NAME" --secret "source=$DB_PASSWORD_SECRET,target=db_password" \
      --env FORM_DB_HOST --env FORM_DB_PORT --env FORM_DB_USER --env FORM_DB_NAME --env FORM_DB_TLS \
      --env FORM_DB_PASSWORD_FILE=/run/secrets/db_password --env DB_CONNECT_TIMEOUT \
      --entrypoint bash "$DB_CLIENT_IMAGE" -euo pipefail -c \
      'export MYSQL_PWD="$(cat "$FORM_DB_PASSWORD_FILE")"; args=(--protocol=TCP --host="$FORM_DB_HOST" --port="$FORM_DB_PORT" --user="$FORM_DB_USER" --connect-timeout="$DB_CONNECT_TIMEOUT"); if [[ "$FORM_DB_TLS" == verify ]]; then args+=(--ssl --ssl-verify-server-cert); else args+=(--skip-ssl); fi; [[ -z "${DB_CLIENT_CA_FILE:-}" ]] || args+=("--ssl-ca=$DB_CLIENT_CA_FILE"); exec mariadb "${args[@]}" "$FORM_DB_NAME" -Nse "SELECT 1"' >/dev/null
    wait_job "${STACK}_dbcheck"
    docker service rm "${STACK}_dbcheck" >/dev/null
  else
    # shellcheck source=scripts/db-common.sh
    source "$BASE/../../scripts/db-common.sh"
    db_init
    db_tool mariadb "$FORM_DB_NAME" -Nse 'SELECT 1' >/dev/null
  fi
}
wait_rollout() {
  local service=$1 replicas=$2 end=$((SECONDS + WAIT_SECONDS)) state count
  while (( SECONDS < end )); do
    state=$(docker service inspect "$service" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')
    count=$(docker service ls --filter "name=$service" --format '{{.Name}} {{.Replicas}}' | awk -v name="$service" '$1 == name {print $2}')
    case "$state" in paused|rollback*) fail "Rollout $service $state; Schema nicht zurückgesetzt" ;; esac
    [[ ( -z "$state" || "$state" == completed ) && "$count" == "$replicas/$replicas" ]] && return
    sleep 3
  done
  fail "Rolling Update $service: Timeout"
}
public_health() {
  local end=$((SECONDS + WAIT_SECONDS)) url=${HEALTHCHECK_URL:-$FORM_ADMIN_ORIGIN/ready}
  while (( SECONDS < end )); do
    if curl --fail --silent --show-error --connect-timeout 3 --max-time 5 "$url" >/dev/null 2>&1; then return; fi
    sleep 3
  done
  fail 'Öffentliches /ready nicht erreichbar; externen Proxy, DNS, TLS und App prüfen'
}
swarm_deploy() {
  local state key service
  for service in app app-pinned; do
    state=$(docker service inspect "${STACK}_$service" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)
    [[ "$state" != updating && "$state" != rollback_started ]] || fail "Ein Rollout läuft bereits: $service"
  done
  docker service inspect "${STACK}_migrate" >/dev/null 2>&1 && fail 'Alter Migrationsservice vorhanden; Zustand prüfen'
  ensure_configs
  env_args=()
  for key in $CONFIG_KEYS; do
    case "$key" in FORM_*|LOG_LEVEL)
      [[ -z "${!key+x}" ]] || env_args+=(--env "$key") ;;
    esac
  done
  UNLOCK_SAFE=0
  docker service create --quiet --with-registry-auth --name "${STACK}_migrate" --restart-condition none \
    ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"} --network "$NETWORK_NAME" --user "$APP_UID:$APP_GID" --limit-cpu "$MIGRATION_CPUS" --limit-memory "$MIGRATION_MEMORY" \
    --secret "source=$DB_PASSWORD_SECRET,target=$FORM_DB_PASSWORD_FILE,uid=$APP_UID,gid=$APP_GID,mode=0400" \
    --config "source=$ENTRY_CONFIG,target=$ENTRYPOINT_PATH" --entrypoint bash \
    "${env_args[@]}" --env "FORM_DB_PASSWORD_FILE=$FORM_DB_PASSWORD_FILE" \
    "$FORM_IMAGE" "$ENTRYPOINT_PATH" migrate >/dev/null
  wait_job "${STACK}_migrate"
  docker service rm "${STACK}_migrate" >/dev/null
  render_swarm | docker stack deploy --with-registry-auth -c - "$STACK"
  wait_rollout "${STACK}_app" "$FORM_REPLICAS"
  wait_rollout "${STACK}_app-pinned" "$FORM_PINNED_EFFECTIVE_REPLICAS"
}
run_admin() {
  local key service out
  [[ "$ADMIN_USER" =~ ^[a-z][a-z0-9._-]{0,63}$ ]] || fail 'Ungültiger Benutzername'
  if [[ "$MODE" == compose ]]; then
    compose run --rm --no-deps -T app "$ADMIN_CMD" "$ADMIN_USER"
    return
  fi
  # Swarm: one-off replicated job with the same image, network, ENV and secrets as the app service.
  service="${STACK}_admin"
  docker service inspect "$service" >/dev/null 2>&1 && docker service rm "$service" >/dev/null
  ensure_configs
  env_args=()
  for key in $CONFIG_KEYS; do
    case "$key" in FORM_*|LOG_LEVEL) [[ -z "${!key+x}" ]] || env_args+=(--env "$key") ;; esac
  done
  secret_args=(--secret "source=$DB_PASSWORD_SECRET,target=$FORM_DB_PASSWORD_FILE,uid=$APP_UID,gid=$APP_GID,mode=0400"
               --secret "source=$SERVER_KEY_SECRET,target=$FORM_SERVER_KEY_FILE,uid=$APP_UID,gid=$APP_GID,mode=0400")
  if docker secret inspect "$BOOTSTRAP_PASSWORD_SECRET" >/dev/null 2>&1; then
    secret_args+=(--secret "source=$BOOTSTRAP_PASSWORD_SECRET,target=$FORM_BOOTSTRAP_PASSWORD_FILE,uid=$APP_UID,gid=$APP_GID,mode=0400")
  fi
  docker service create --quiet --with-registry-auth --name "$service" --restart-condition none \
    ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"} --network "$NETWORK_NAME" --user "$APP_UID:$APP_GID" \
    "${secret_args[@]}" --config "source=$ENTRY_CONFIG,target=$ENTRYPOINT_PATH" --entrypoint bash \
    "${env_args[@]}" --env "FORM_DB_PASSWORD_FILE=$FORM_DB_PASSWORD_FILE" --env "FORM_SERVER_KEY_FILE=$FORM_SERVER_KEY_FILE" \
    "$FORM_IMAGE" "$ENTRYPOINT_PATH" "$ADMIN_CMD" "$ADMIN_USER" >/dev/null
  wait_job "$service" || { docker service logs "$service" 2>&1 | tail -20; docker service rm "$service" >/dev/null 2>&1; return 1; }
  out=$(docker service logs --raw "$service" 2>&1 || true)
  docker service rm "$service" >/dev/null
  printf '%s\n' "$out"
}
main() {
  local rc=0
  initialize "$@" || rc=$?
  [[ "$rc" != 10 ]] || return 0
  if [[ "$ACTION" == admin ]]; then
    if [[ "$DRY" == 1 ]]; then say "Trockenlauf: würde '$ADMIN_CMD $ADMIN_USER' mit Image $FORM_IMAGE im Stack $STACK ausführen."; return; fi
    umask 077; need docker
    run_admin; return
  fi
  if [[ "$DRY" == 1 ]]; then plan; return; fi
  umask 077; need docker; need curl; need openssl
  [[ "$MODE" != compose ]] || docker compose version >/dev/null
  acquire_lock
  if [[ "$ACTION" == setup ]]; then prepare_secrets; fi
  unset FORM_DB_PASSWORD FORM_SERVER_KEY FORM_BOOTSTRAP_PASSWORD
  ensure_network
  say "Image ziehen: $FORM_IMAGE"
  docker pull "$FORM_IMAGE"
  FORM_IMAGE=$(docker image inspect "$FORM_IMAGE" --format '{{index .RepoDigests 0}}'); export FORM_IMAGE
  [[ "$FORM_IMAGE" == *@sha256:* ]] || fail 'Image-Digest nicht ermittelbar'
  if [[ "$ACTION" == setup ]]; then save_config; fi
  if [[ "$MODE" == swarm ]]; then render_swarm | docker stack config -c - >/dev/null
  else compose --profile tools config --quiet; fi
  check_db
  if [[ "$MODE" == swarm ]]; then swarm_deploy
  else
    compose pull app migrate
    UNLOCK_SAFE=0
    compose run --rm --no-deps -T migrate
    compose up -d --wait --wait-timeout "$WAIT_SECONDS" app
  fi
  public_health; save_config; UNLOCK_SAFE=1
  say "Deployment erfolgreich; Digest in $ENV_FILE (0600). DB und TLS-Proxy bleiben extern."
}
