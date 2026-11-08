#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Einstellungen der Env-Datei per Menü (whiptail, wie raspi-config) oder per Kommandozeile bearbeiten.
#
# Aufruf: deploy/swarm/settings.sh bzw. deploy/compose/settings.sh [Optionen]
#   (ohne Aktion)     Menü starten (braucht whiptail oder dialog)
#   --env PFAD        Env-Datei (Standard: swarm deploy/swarm/stack.env, compose deploy/compose/.env)
#   --list            alle Variablen mit Wert, Default und Quelle
#   --get KEY         Wert einer Variablen ausgeben (Geheimnisse nie)
#   --set KEY=VALUE   Wert prüfen und speichern (mit Sicherung); mehrfach möglich
#   --unset KEY       Variable aus der Datei nehmen (zurück auf den Default); mehrfach möglich
#   --info KEY        ausführliche Erklärung einer Variablen (Zweck, Beispiele, Abgrenzung zu ähnlichen Variablen)
#   --check           gesamte Datei prüfen (Typ, Grenzen, Konflikte, unbekannte Variablen, Secrets)
#   -h, --help        diese Hilfe
#
# Quelle der Metadaten: config-registry.tsv (aus SettingsRegistry erzeugt), config-extra.tsv (Deploy-Variablen), config-help.tsv
# (ausführliche Erklärungen, optional), dazu die
# Vorlage stack.env.example bzw. .env.example (welche Variablen es im Modus gibt, Vorlagenwerte als Default).
# Geheimnisse (DB-Passwort, Server-Key, Bootstrap-Passwort) werden nie angezeigt oder in die Datei geschrieben.
# Gespeichert wird atomar mit Modus 0600; vorher entsteht eine Sicherung <Datei>.bak.JJJJMMTT-HHMMSS.
# Es wird nichts ausgerollt, solange man es nicht im Menü ("Jetzt anwenden") bestätigt; --set/--unset rollen nie aus.
# shellcheck disable=SC2016  # $ und Backtick stehen absichtlich in einfachen Anführungszeichen
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "settings.sh braucht Bash 4.4 oder neuer (gefunden: ${BASH_VERSION}). macOS liefert Bash 3.2; auf dem Server (Linux) ist Bash 5 üblich." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${SETTINGS_MODE:-swarm}"
case "$MODE" in swarm|compose) ;; *) echo "Unbekannter Modus: $MODE" >&2; exit 64 ;; esac
MODE_DIR="$(cd "$SCRIPT_DIR/../$MODE" && pwd)"
if [ "$MODE" = swarm ]; then
  TEMPLATE="$MODE_DIR/stack.env.example"; DEFAULT_ENV="$MODE_DIR/stack.env"
else
  TEMPLATE="$MODE_DIR/.env.example"; DEFAULT_ENV="$MODE_DIR/.env"
fi
TSV_REGISTRY="${SETTINGS_REGISTRY:-$SCRIPT_DIR/config-registry.tsv}"
TSV_EXTRA="${SETTINGS_EXTRA:-$SCRIPT_DIR/config-extra.tsv}"
TSV_HELP="${SETTINGS_HELP:-$SCRIPT_DIR/config-help.tsv}"
ENV_FILE=""
BACKTITLE="form-backend ($MODE): Einstellungen"
# Geheimnisse, die update.sh aus dem Prozess-ENV akzeptiert, die aber nie in der Datei stehen dürfen.
SECRET_ENV_KEYS=" FORM_DB_PASSWORD FORM_SERVER_KEY FORM_BOOTSTRAP_PASSWORD "
# Compose hat keine Docker-Secrets: dort sind die drei Werte gewöhnliche (verdeckt angezeigte) ENV-Werte der 0600-Datei. setup.sh/update.sh
# legen daraus die Secret-Dateien an, wenn sie fehlen. Swarm: nie in der Datei.
PLAIN_SECRETS=""
if [ "$MODE" = compose ]; then PLAIN_SECRETS=" FORM_DB_PASSWORD FORM_SERVER_KEY FORM_BOOTSTRAP_PASSWORD "; SECRET_ENV_KEYS=" "; fi
is_masked() { [[ $PLAIN_SECRETS == *" $1 "* ]] || is_secretlike "$1"; }
# Ports haben bewusst keine _FILE-Variante (lib.sh lehnt sie ab).
NO_FILE_KEYS=" FORM_PUBLIC_PORT FORM_INTERNAL_PORT "

die() { echo "Fehler: $*" >&2; exit 1; }

# ---------------------------------------------------------------- Tabellen und Vorlage
declare -a KEYS=()
declare -A T_GROUP=() T_TYPE=() T_DEF=() T_UNIT=() T_MIN=() T_MAX=() T_CHOICES=() T_APPLY=() T_SECRET=() T_SUM=()
declare -A TPL_KEY=() TPL_VAL=() T_HELP=()

load_help() { # optionale Datei key<TAB>Text; "\n" im Text = Zeilenumbruch
  local k t
  [ -r "$TSV_HELP" ] || return 0
  while IFS=$'\x1f' read -r k t; do
    [ -n "$k" ] || continue
    T_HELP[$k]="${t//\\n/$'\n'}"
  done < <(awk -F'\t' -v OFS='\037' '!/^#/ && NF >= 2 { print $1, $2 }' "$TSV_HELP")
}

load_table() { # Datei
  local f="$1" k g ty d u mn mx ch ap se sm
  [ -r "$f" ] || die "Tabelle fehlt: $f (der Deploy-Branch enthält config-registry.tsv und config-extra.tsv)"
  # Unit Separator als Trenner: Tabulatoren würden leere Felder zusammenziehen.
  while IFS=$'\x1f' read -r k g ty d u mn mx ch ap se sm; do
    [ -n "$k" ] || continue
    if [ -n "${T_GROUP[$k]+x}" ]; then continue; fi
    T_GROUP[$k]="$g"; T_TYPE[$k]="$ty"; T_DEF[$k]="$d"; T_UNIT[$k]="$u"; T_MIN[$k]="$mn"; T_MAX[$k]="$mx"
    T_CHOICES[$k]="$ch"; T_APPLY[$k]="$ap"; T_SECRET[$k]="$se"; T_SUM[$k]="$sm"
  done < <(awk -F'\t' -v OFS='\037' '!/^#/ && NF >= 11 { $1 = $1; print }' "$f")
}

load_template() { # welche Variablen es im Modus gibt; aktive Zeilen liefern den Vorlagenwert als Default
  local line key val
  [ -r "$TEMPLATE" ] || die "Vorlage fehlt: $TEMPLATE"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ $line =~ ^(#\ )?([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
      TPL_KEY[$key]=1
      if [ -z "${BASH_REMATCH[1]}" ]; then
        case "$val" in \"*\"|\'*\') val="${val:1:${#val}-2}" ;; esac
        TPL_VAL[$key]="$val"
      fi
    fi
  done < "$TEMPLATE"
}

# Tabellen laden, Reihenfolge der Vorlage nicht nötig: erst Register, dann Extra, dann *_FILE-Varianten.
load_tables() {
  local k base
  declare -A seen=()
  load_table "$TSV_REGISTRY"; load_table "$TSV_EXTRA"; load_help
  load_template
  if [ "$MODE" = compose ]; then
    local pk
    for pk in FORM_DB_PASSWORD FORM_SERVER_KEY FORM_BOOTSTRAP_PASSWORD; do
      [ -n "${T_GROUP[$pk]+x}" ] || continue
      T_SECRET[$pk]=0; T_DEF[$pk]=""; T_MAX[$pk]=200; T_APPLY[$pk]="envOnly"
      case "$pk" in
        FORM_SERVER_KEY) T_TYPE[$pk]="text:hexkey?"; T_SUM[$pk]="Server-Key (64 Hexzeichen) als einfache ENV. Beim ersten Rollout entsteht daraus die Secret-Datei; ein vorhandener Key lässt sich nicht ändern." ;;
        FORM_DB_PASSWORD) T_TYPE[$pk]="text:secretval?"; T_SUM[$pk]="Passwort des DB-Benutzers als einfache ENV (Wert wird verdeckt angezeigt). Leer = Setup fragt danach bzw. nutzt die Secret-Datei." ;;
        *) T_TYPE[$pk]="text:secretval?"; T_SUM[$pk]="Einmaliges Start-Passwort des ersten Administrators als einfache ENV. Leer = der Server erzeugt eines." ;;
      esac
    done
  fi
  # Reihenfolge: Tabellenzeilen in Dateireihenfolge, soweit die Vorlage des Modus die Variable kennt.
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    # Docker-Secret-Namen gibt es nur in Swarm; Compose liest die Secrets aus Dateien (*_SOURCE_FILE).
    if [ "$MODE" = compose ]; then case "$k" in DB_PASSWORD_SECRET|SERVER_KEY_SECRET|BOOTSTRAP_PASSWORD_SECRET) continue ;; esac; fi
    if [ -n "${TPL_KEY[$k]+x}" ] && [ -z "${seen[$k]+x}" ]; then KEYS+=("$k"); seen[$k]=1; fi
  done < <(awk -F'\t' '!/^#/ && NF >= 11 { print $1 }' "$TSV_REGISTRY" "$TSV_EXTRA")
  # KEY_FILE ohne eigene Zeile: Datei mit dem Wert von KEY (der Wrapper liest sie im Container).
  for k in $(printf '%s\n' "${!TPL_KEY[@]}" | sort); do
    [[ $k == *_FILE ]] || continue
    [ -z "${T_GROUP[$k]+x}" ] || continue
    base="${k%_FILE}"
    [ -n "${T_GROUP[$base]+x}" ] || continue
    T_GROUP[$k]="Dateivarianten"; T_DEF[$k]=""; T_UNIT[$k]=""; T_MIN[$k]=""; T_MAX[$k]=500; T_CHOICES[$k]=""
    T_APPLY[$k]="envOnly"; T_SECRET[$k]=0
    if [[ $NO_FILE_KEYS == *" $base "* ]]; then
      T_TYPE[$k]="unsupported"; T_SUM[$k]="Nicht unterstützt: $base direkt setzen."
    else
      T_TYPE[$k]="text:cpath?"; T_SUM[$k]="Containerpfad einer Datei mit dem Wert von $base (überschreibt ihn; nur der Pfad)."
      KEYS+=("$k")
    fi
  done
}

default_of() { # Vorlagenwert (aktive Zeile) vor Tabellenwert
  if [ -n "${TPL_VAL[$1]+x}" ]; then printf '%s' "${TPL_VAL[$1]}"; else printf '%s' "${T_DEF[$1]-}"; fi
}

is_secretlike() { # Tabelle entscheidet; unbekannte Namen mit PASSWORD/KEY/SECRET/TOKEN gelten vorsichtshalber als Geheimnis
  local k="$1"
  if [ -n "${T_SECRET[$k]+x}" ]; then [ "${T_SECRET[$k]}" = 1 ]; return; fi
  local up="${k^^}"
  [[ $up == *PASSWORD* || $up == *PASSWD* || $up == *SECRET* || $up == *KEY* || $up == *TOKEN* || $up == *CREDENTIAL* ]]
}
is_known() { [ -n "${T_GROUP[$1]+x}" ] && [ -n "${TPL_KEY[$1]+x}" ]; }

apply_label() {
  case "${T_APPLY[$1]}" in
    live) echo "live" ;;
    restart) echo "Neustart" ;;
    *) echo "nur ENV" ;;
  esac
}
secret_hint() {
  printf '%s ist ein Geheimnis und steht nie in der Env-Datei.\n\nDie Quelle ist eine geschützte Datei auf dem Host (<Modus>/secrets/ oder --db-password-file / --server-key-file beim Setup); Setup legt daraus ein Docker-Secret an. Ein Secret lässt sich nicht ändern: zum Ersetzen unter neuem Namen anlegen (…_SECRET) und ausrollen.' "$1"
}

# ---------------------------------------------------------------- Env-Datei lesen
declare -a ENV_LINES=()
declare -A ENV_VAL=() ENV_COUNT=() ENV_BAD=()
declare -a ENV_BADLINES=()
declare -A PEND_SET=() PEND_UNSET=()
ENV_EXISTS=0

# Genau wie lib.sh read_config: nur ein umschließendes Anführungszeichenpaar wird entfernt, nichts wird expandiert.
env_load() {
  local line key value n=0
  ENV_LINES=(); ENV_VAL=(); ENV_COUNT=(); ENV_BAD=(); ENV_BADLINES=(); ENV_EXISTS=0
  [ -f "$ENV_FILE" ] || return 0
  ENV_EXISTS=1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; n=$((n + 1))
    ENV_LINES+=("$line")
    case "$line" in ''|'#'*) continue ;; esac
    if [[ $line != *=* ]]; then ENV_BADLINES+=("Zeile $n: KEY=VALUE erwartet"); continue; fi
    key="${line%%=*}"; value="${line#*=}"
    if ! [[ $key =~ ^[A-Z][A-Z0-9_]+$ ]]; then ENV_BADLINES+=("Zeile $n: ungültiger Variablenname"); continue; fi
    case "$value" in \"*\"|\'*\') value="${value:1:${#value}-2}" ;; esac
    ENV_VAL[$key]="$value"
    ENV_COUNT[$key]=$(( ${ENV_COUNT[$key]:-0} + 1 ))
    if [[ $value == *'$'* || $value == *'`'* || $value == *\\* ]]; then ENV_BAD[$key]="enthält \$, Backtick oder Backslash (update.sh lehnt das ab)"
    else unset 'ENV_BAD[$key]'; fi
  done < "$ENV_FILE"
}

# Wert so schreiben, dass lib.sh ihn unverändert liest: Anführungszeichen, JSON mit " in einfachen Anführungszeichen.
quote_value() {
  if [[ $1 == *'"'* ]]; then printf "'%s'" "$1"; else printf '"%s"' "$1"; fi
}

# ---------------------------------------------------------------- wirksamer Zustand (Datei + offene Änderungen)
in_file() { [ -n "${ENV_COUNT[$1]+x}" ]; }
is_set() {
  if [ -n "${PEND_UNSET[$1]+x}" ]; then return 1; fi
  if [ -n "${PEND_SET[$1]+x}" ]; then return 0; fi
  in_file "$1"
}
eff_value() {
  local k="$1"
  if [ -n "${PEND_UNSET[$k]+x}" ]; then default_of "$k"
  elif [ -n "${PEND_SET[$k]+x}" ]; then printf '%s' "${PEND_SET[$k]}"
  elif in_file "$k"; then printf '%s' "${ENV_VAL[$k]}"
  else default_of "$k"; fi
}
queue_set() { # KEY WERT (bereits geprüft)
  unset 'PEND_UNSET[$1]'
  if [ -z "${PEND_SET[$1]+x}" ] && in_file "$1" && [ "${ENV_VAL[$1]}" = "$2" ] && [ "${ENV_COUNT[$1]}" = 1 ]; then return 0; fi
  PEND_SET[$1]="$2"
}
queue_unset() {
  unset 'PEND_SET[$1]'
  if in_file "$1"; then PEND_UNSET[$1]=1; fi
}
pending_count() { echo $(( ${#PEND_SET[@]} + ${#PEND_UNSET[@]} )); }

# ---------------------------------------------------------------- Validierung
V_ERR=""

ip_ok() { # IPv4/IPv6 ohne Präfix
  local ip="$1" o
  local -a parts
  if [[ $ip == *:* ]]; then
    [[ $ip =~ ^[0-9A-Fa-f:.]+$ && $ip == *:*:* ]] && [[ $ip != *:::* ]] && [[ $ip != *::*::* ]]; return
  fi
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -ra parts <<< "$ip"
  for o in "${parts[@]}"; do [ $((10#$o)) -le 255 ] || return 1; done
}
cidr_ok() { # IP oder IP/Präfix
  local c="$1" ip pre="" max=32
  ip="${c%%/*}"
  if [[ $c == */* ]]; then pre="${c#*/}"; [[ $pre =~ ^[0-9]{1,3}$ ]] || return 1; fi
  ip_ok "$ip" || return 1
  [[ $ip == *:* ]] && max=128
  [ -z "$pre" ] || [ $((10#$pre)) -le "$max" ]
}
cidrs_ok() { # kommagetrennt, keine leeren Einträge
  local v="$1" item
  [[ $v != ,* && $v != *, && $v != *,,* ]] || return 1
  local IFS=,
  for item in $v; do cidr_ok "$item" || return 1; done
}
mailbox_ok() {
  local v="$1" local_part domain label
  [ "${#v}" -le 254 ] || return 1
  [[ $v =~ ^[A-Za-z0-9._%+!-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || return 1
  local_part="${v%@*}"; domain="${v#*@}"
  [ "${#local_part}" -le 64 ] && [[ $local_part != .* && $local_part != *. && $local_part != *..* ]] || return 1
  local IFS=.
  for label in $domain; do
    [ -n "$label" ] && [ "${#label}" -le 63 ] && [[ $label != -* && $label != *- ]] || return 1
  done
}
json_list_items() { # JSON-Liste von Strings (ohne Escapes, die Datei erlaubt keinen Backslash) -> JL_ITEMS; Rückgabe 1 = ungültig
  local v="$1" rest
  JL_ITEMS=()
  [[ $v =~ ^\[[[:space:]]*(.*[^[:space:]])?[[:space:]]*\]$ ]] || { [[ $v =~ ^\[[[:space:]]*\]$ ]] && return 0; return 1; }
  rest="${BASH_REMATCH[1]}"
  [ -n "$rest" ] || return 0
  while :; do
    [[ $rest =~ ^\"([^\"]*)\"[[:space:]]*(.*)$ ]] || return 1
    JL_ITEMS+=("${BASH_REMATCH[1]}"); rest="${BASH_REMATCH[2]}"
    [ -n "$rest" ] || return 0
    [[ $rest == ,* ]] || return 1
    rest="${rest#,}"; rest="${rest#"${rest%%[![:space:]]*}"}"
    [ -n "$rest" ] || return 1
  done
}

validate_text() { # KEY WERT REGEL (KEY ungenutzt, für Meldungen reserviert) (Rückgabe 0 = gültig, sonst V_ERR)
  local val="$2" rule="$3" item
  case "$rule" in
    free) ;;
    secretval) [[ $val =~ ^[[:print:]]{1,200}$ && $val != *[\$\`\\\"\']* ]] || { V_ERR='1 bis 200 druckbare Zeichen ohne $ ` \ " und Apostroph'; return 1; } ;;
    hexkey) [[ $val =~ ^[a-fA-F0-9]{64}$ ]] || { V_ERR='64 Hexzeichen (z. B. openssl rand -hex 32)'; return 1; } ;;
    hostaddr) [[ $val =~ ^[A-Za-z0-9.:_-]+$ && $val != -* ]] || { V_ERR="Hostname oder IP-Adresse (Buchstaben, Ziffern, . : _ -)"; return 1; } ;;
    dbhost) [[ $val =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]] || { V_ERR="Hostname oder IP-Adresse des DB-Servers"; return 1; } ;;
    dbuser) [[ $val =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$ ]] || { V_ERR="Buchstabe am Anfang, dann Buchstaben, Ziffern, _ . - (höchstens 64 Zeichen)"; return 1; } ;;
    dbident) [[ $val =~ ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ ]] || { V_ERR="Buchstabe am Anfang, dann Buchstaben, Ziffern, _ (höchstens 64 Zeichen)"; return 1; } ;;
    mailbox) mailbox_ok "$val" || { V_ERR="gültige E-Mail-Adresse erwartet"; return 1; } ;;
    uuid) [[ $val =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { V_ERR="UUID erwartet"; return 1; } ;;
    cidrs) cidrs_ok "$val" || { V_ERR="CIDR-Liste erwartet, kommagetrennt, z. B. 10.0.0.0/8,192.0.2.1/32"; return 1; } ;;
    jsonpatterns|jsonhashes|jsonrecipients)
      [ "${#val}" -le 4096 ] || { V_ERR="höchstens 4096 Zeichen"; return 1; }
      json_list_items "$val" || { V_ERR="JSON-Liste von Texten erwartet, z. B. [\"a\",\"b\"]"; return 1; }
      [ "${#JL_ITEMS[@]}" -le 200 ] || { V_ERR="höchstens 200 Einträge"; return 1; }
      for item in ${JL_ITEMS[@]+"${JL_ITEMS[@]}"}; do
        [ -n "$item" ] && [ "${#item}" -le 200 ] || { V_ERR="Einträge nicht leer, höchstens 200 Zeichen"; return 1; }
        case "$rule" in
          jsonhashes) [[ $item =~ ^[0-9a-f]{64}$ ]] || { V_ERR="Hash: genau 64 Hex-Zeichen in Kleinbuchstaben"; return 1; } ;;
          jsonrecipients) [[ $item == *@* && ! $item =~ [[:space:],] ]] || { V_ERR="Empfänger: E-Mail-Adresse ohne Leerzeichen und Komma"; return 1; } ;;
        esac
      done ;;
    origin) [[ $val =~ ^https://[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?$ ]] || { V_ERR="https://host[:port] in Kleinbuchstaben, ohne Pfad"; return 1; } ;;
    host) [[ $val =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { V_ERR="Hostname in Kleinbuchstaben, ohne Schema und Port"; return 1; } ;;
    path) [[ $val == /* && $val != *..* ]] || { V_ERR="absoluter Pfad ohne .."; return 1; } ;;
    cpath) [[ $val == /* && $val != *..* && ! $val =~ [[:space:]] ]] || { V_ERR="absoluter Containerpfad ohne Leerzeichen und .."; return 1; } ;;
    hostpath) [[ $val != -* ]] || { V_ERR="Pfad darf nicht mit - beginnen"; return 1; } ;;
    hostlist) [[ $val =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(,[a-z0-9]([a-z0-9.-]*[a-z0-9])?)*$ ]] || { V_ERR="Hostnamen in Kleinbuchstaben, kommagetrennt, ohne Schema, Port, Wildcard"; return 1; } ;;
    stackname) [[ $val =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { V_ERR="Kleinbuchstaben, Ziffern, Bindestrich; beginnt mit Buchstabe; höchstens 31 Zeichen"; return 1; } ;;
    imagetag) [[ $val =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { V_ERR="ungültiges Image-Tag"; return 1; } ;;
    imageref) [[ $val =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]+$ ]] || { V_ERR="ungültige Image-Referenz"; return 1; } ;;
    memlimit) [[ $val =~ ^[0-9]+(\.[0-9]+)?[bBkKmMgG]?$ ]] || { V_ERR="Zahl mit optionaler Einheit, z. B. 512M"; return 1; } ;;
    duration) [[ $val =~ ^([0-9]+(ns|us|ms|s|m|h))+$ ]] || { V_ERR="Dauer wie 10s, 1m30s, 500ms"; return 1; } ;;
    dockername|secretname|nodeid) [[ $val =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]] || { V_ERR="Buchstaben, Ziffern, _ . - (höchstens 64 Zeichen)"; return 1; } ;;
    constraints)
      [[ $val != ,* && $val != *, ]] || { V_ERR="leerer Listeneintrag"; return 1; }
      local IFS=,
      for item in $val; do
        item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
        [[ $item =~ ^[a-zA-Z0-9_.-]+[[:space:]]*(==|!=)[[:space:]]*[a-zA-Z0-9_./:@-]+$ ]] || { V_ERR="Constraint erwartet, z. B. node.labels.zone==a"; return 1; }
      done ;;
    preferences)
      [[ $val != ,* && $val != *, ]] || { V_ERR="leerer Listeneintrag"; return 1; }
      local IFS=,
      for item in $val; do
        item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
        [[ $item =~ ^spread=(node|engine)\.labels\.[a-zA-Z0-9_.-]+$ ]] || { V_ERR="Präferenz erwartet, z. B. spread=node.labels.zone"; return 1; }
      done ;;
    httpurl) [[ $val =~ ^https?://[^[:space:]]+$ ]] || { V_ERR="http(s)-Adresse ohne Leerzeichen"; return 1; } ;;
    *) V_ERR="unbekannte Regel '$rule' in der Tabelle"; return 1 ;;
  esac
  return 0
}

# Prüft einen Wert gegen die Tabelle; Rückgabe 0 = gültig. Leer ist gültig, wenn der Default leer ist oder die Regel auf ? endet.
validate() { # KEY WERT
  local key="$1" val="$2" type base rule="" lo hi n opt=0 def
  type="${T_TYPE[$key]}"; base="${type%%:*}"; [[ $type == *:* ]] && rule="${type#*:}"
  if [[ $rule == *\? ]]; then rule="${rule%\?}"; opt=1; fi
  lo="${T_MIN[$key]}"; hi="${T_MAX[$key]}"; def="$(default_of "$key")"
  V_ERR=""
  if [[ $val =~ [[:cntrl:]] ]]; then V_ERR="Steuerzeichen und Zeilenumbrüche sind nicht erlaubt"; return 1; fi
  if [[ $val == *'$'* || $val == *'`'* || $val == *\\* ]]; then V_ERR="\$, Backtick und Backslash sind nicht erlaubt (update.sh lehnt sie ab)"; return 1; fi
  if [[ $val == *'"'* && $val == *"'"* ]]; then V_ERR="gemischte Anführungszeichen (\" und ') werden nicht unterstützt"; return 1; fi
  if [ "$base" = secret ]; then V_ERR="Geheimnisse gehören nicht in die Datei"; return 1; fi
  if [ "$base" = unsupported ]; then V_ERR="nicht unterstützt (Port direkt setzen)"; return 1; fi
  if [ -z "$val" ]; then
    if [ -z "$def" ] || [ "$opt" = 1 ]; then return 0; fi
    V_ERR="leerer Wert nicht erlaubt (Default: $def); zum Zurücksetzen --unset verwenden"; return 1
  fi
  case "$base" in
    int)
      [[ $val =~ ^(0|[1-9][0-9]{0,11})$ ]] || { V_ERR="muss eine ganze Zahl sein (ohne führende Nullen)"; return 1; }
      n=$((10#$val))
      if [ "$n" -lt "$lo" ] || [ "$n" -gt "$hi" ]; then V_ERR="muss zwischen $lo und $hi liegen"; return 1; fi ;;
    number)
      [[ $val =~ ^[0-9]{1,9}(\.[0-9]{1,6})?$ ]] || { V_ERR="muss eine Zahl sein (Dezimalpunkt)"; return 1; }
      awk -v v="$val" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }' \
        || { V_ERR="muss zwischen $lo und $hi liegen"; return 1; } ;;
    bool) [ "$val" = true ] || [ "$val" = false ] || { V_ERR="muss true oder false sein (Kleinbuchstaben)"; return 1; } ;;
    choice) [[ "|${T_CHOICES[$key]}|" == *"|$val|"* ]] || { V_ERR="erlaubt: ${T_CHOICES[$key]//|/, }"; return 1; } ;;
    text)
      [ "${#val}" -le "$hi" ] || { V_ERR="höchstens $hi Zeichen"; return 1; }
      validate_text "$key" "$val" "$rule" || return 1 ;;
    *) V_ERR="unbekannter Typ '$type' in der Tabelle"; return 1 ;;
  esac
  return 0
}

describe_type() {
  local k="$1" t="${T_TYPE[$1]}" base="${T_TYPE[$1]%%:*}" r="" u="${T_UNIT[$1]}"
  [[ $t == *:* ]] && r="${t#*:}"
  local opt=""; [[ $r == *\? ]] && { r="${r%\?}"; opt=", leer erlaubt"; }
  case "$base" in
    int) echo "Ganzzahl ${T_MIN[$k]} bis ${T_MAX[$k]}${u:+ $u}${opt}" ;;
    number) echo "Zahl ${T_MIN[$k]} bis ${T_MAX[$k]}${u:+ $u}" ;;
    bool) echo "true oder false" ;;
    choice) echo "Auswahl: ${T_CHOICES[$k]//|/, }" ;;
    secret) echo "Geheimnis (nie in der Datei)" ;;
    unsupported) echo "nicht unterstützt" ;;
    text) echo "Text (${r:-free}), höchstens ${T_MAX[$k]} Zeichen$opt" ;;
    *) echo "$base" ;;
  esac
}

effect_text() {
  case "${T_APPLY[$1]}" in
    live) echo "live: im Dashboard änderbar; ein Wert in der Datei hat Vorrang und sperrt das Feld, wirkt nach \"Jetzt anwenden\"" ;;
    restart) echo "Neustart: wird beim Start gelesen; wirkt nach \"Jetzt anwenden\"" ;;
    *) echo "nur ENV: nur über die Datei, wirkt nach \"Jetzt anwenden\"" ;;
  esac
}

# ---------------------------------------------------------------- Prüfung der gesamten Datei
declare -a CHK_ERR=() CHK_WARN=() CHK_NOTE=()
chk_err() { CHK_ERR+=("$*"); }
chk_warn() { CHK_WARN+=("$*"); }
chk_note() { CHK_NOTE+=("$*"); }

# Autoritative Prüfung: dieselbe Validierung wie update.sh (lib.sh). Läuft in sauberer Umgebung gegen die übergebene Datei.
lib_check() { # Datei -> Fehlermeldung auf stdout (leer = in Ordnung)
  local f="$1" out
  [ -r "$MODE_DIR/../swarm/lib.sh" ] || return 0
  out="$(env -i PATH="$PATH" HOME="${HOME:-/}" "$BASH" -c \
    'BASE=$1; MODE=$2; ACTION=update; source "$1/../swarm/lib.sh"; initialize --non-interactive --env-file "$3"' _ "$MODE_DIR" "$MODE" "$f" 2>&1 >/dev/null </dev/null)" || true
  out="${out#Fehler: }"
  [ -z "$out" ] || printf '%s' "${out%%$'\n'*}"
}

effective_env_file() { # Datei mit dem Zustand inkl. offener Änderungen (für lib_check); Pfad in EFF_TMP
  EFF_TMP=""
  if [ "$(pending_count)" -eq 0 ]; then EFF_TMP="$ENV_FILE"; return 0; fi
  build_new_lines
  EFF_TMP="$(umask 077; mktemp "$(dirname "$ENV_FILE")/.settings-check.XXXXXX")"
  TMPFILES+=("$EFF_TMP")
  if [ "${#NEW_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NEW_LINES[@]}" > "$EFF_TMP"; else : > "$EFF_TMP"; fi
}

check_all() {
  CHK_ERR=(); CHK_WARN=(); CHK_NOTE=()
  local k v msg line mode
  if [ "$ENV_EXISTS" = 0 ]; then
    chk_warn "Datei $ENV_FILE existiert noch nicht; zuerst setup.sh ausführen. Es gelten die Vorlagenwerte."
  else
    if [ -L "$ENV_FILE" ]; then chk_err "Env-Datei darf kein Symlink sein (update.sh lehnt das ab)."; fi
    mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '')"
    if [ -n "$mode" ] && [ "$mode" != 600 ]; then chk_warn "Dateimodus ist $mode, erwartet 600 (Speichern setzt 600)."; fi
  fi
  for line in ${ENV_BADLINES[@]+"${ENV_BADLINES[@]}"}; do chk_err "$line"; done
  for k in $(printf '%s\n' ${ENV_VAL[@]+"${!ENV_VAL[@]}"} | sort); do
    [ -n "$k" ] || continue
    v="${ENV_VAL[$k]}"
    if [ -n "${PEND_SET[$k]+x}" ]; then v="${PEND_SET[$k]}"; fi
    if [ -n "${PEND_UNSET[$k]+x}" ]; then continue; fi
    if [ "${ENV_COUNT[$k]}" -gt 1 ]; then chk_warn "$k steht ${ENV_COUNT[$k]}-mal in der Datei; der letzte Wert gilt."; fi
    if [ -n "${ENV_BAD[$k]+x}" ] && [ -z "${PEND_SET[$k]+x}" ]; then chk_err "$k: ${ENV_BAD[$k]}."; fi
    if [[ $SECRET_ENV_KEYS == *" $k "* ]] || { [ -n "${T_SECRET[$k]+x}" ] && [ "${T_SECRET[$k]}" = 1 ]; }; then
      if [ -n "$v" ]; then chk_err "$k: Geheimnis in der Datei. Entfernen (--unset $k); die Quelle ist eine geschützte Datei."
      else chk_warn "$k: gehört nicht in die Datei (leer, wird ignoriert)."; fi
      continue
    fi
    if [ -z "${TPL_KEY[$k]+x}" ]; then
      if is_secretlike "$k"; then chk_err "$k: unbekannte Variable, Name deutet auf ein Geheimnis; update.sh bricht ab."
      else chk_err "$k: unbekannte Variable (nicht in der Vorlage); update.sh bricht ab."; fi
      continue
    fi
    if [ -z "${T_GROUP[$k]+x}" ]; then chk_warn "$k: Variable der Vorlage ohne Eintrag in den Tabellen (nicht geprüft)."; continue; fi
    if [ "${T_TYPE[$k]}" = unsupported ]; then
      [ -z "$v" ] || chk_err "$k: nicht unterstützt (Port direkt setzen)."
      continue
    fi
    if ! validate "$k" "$v"; then chk_err "$k=$v: $V_ERR"; fi
  done
  # Konflikte (Basis ist der wirksame Zustand)
  local internal
  if [ "$(eff_value FORM_DB_TLS)" = disable ] && [ "$(eff_value FORM_ALLOW_INSECURE_DEV)" != 1 ]; then
    chk_err "FORM_DB_TLS=disable benötigt FORM_ALLOW_INSECURE_DEV=1 (erlaubt auch unsichere Mail-/Deploy-Ziele)."
  fi
  if [ "$(eff_value FORM_ALLOW_INSECURE_DEV)" = 1 ]; then chk_warn "FORM_ALLOW_INSECURE_DEV=1 erlaubt unsichere Mail-/Deploy-Ziele und DB-TLS disable; nur für Entwicklung."; fi
  if [ "$(eff_value FORM_PUBLIC_DASHBOARD)" = 1 ] && [ -z "$(eff_value FORM_PUBLIC_DASHBOARD_HOSTS)" ]; then
    chk_err "FORM_PUBLIC_DASHBOARD=1, aber FORM_PUBLIC_DASHBOARD_HOSTS fehlt."
  fi
  internal="$(eff_value FORM_INTERNAL_PORT)"
  if [ -n "$internal" ] && [ "$internal" = "$(eff_value FORM_PUBLIC_PORT)" ]; then chk_err "Öffentlicher und interner Listener benötigen unterschiedliche Ports."; fi
  v="$(eff_value FORM_ADMIN_ORIGIN)"; k="$(eff_value FORM_RP_ID)"
  if [[ $v =~ ^https://([a-z0-9][a-z0-9.-]*)(:[0-9]{1,5})?$ ]] && [ -n "$k" ] && [ "${BASH_REMATCH[1]}" != "$k" ] && [[ ${BASH_REMATCH[1]} != *".$k" ]]; then
    chk_err "FORM_RP_ID ($k) muss zum Host von FORM_ADMIN_ORIGIN (${BASH_REMATCH[1]}) passen."
  fi
  if [ "$ENV_EXISTS" = 1 ]; then
    for k in FORM_ADMIN_ORIGIN FORM_RP_ID FORM_DB_HOST; do
      if [[ "$(eff_value "$k")" == *example.org ]]; then chk_warn "$k steht noch auf dem Platzhalter $(eff_value "$k")."; fi
    done
  fi
  if [ "$MODE" = swarm ] && [ -n "$(eff_value FORM_PINNED_PUBLISH_PORT)$(eff_value FORM_PINNED_PUBLIC_PUBLISH_PORT)" ] && [ -z "$(eff_value FORM_PINNED_NODE)" ]; then
    chk_note "FORM_PINNED_*_PUBLISH_PORT wird nicht veröffentlicht, solange FORM_PINNED_NODE leer ist."
  fi
  # autoritativ: dieselbe Prüfung wie update.sh
  if [ "$ENV_EXISTS" = 1 ]; then
    effective_env_file
    msg="$(lib_check "$EFF_TMP")"
    if [ -n "$msg" ]; then
      local dup=0 e
      for e in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do [[ $e == *"$msg"* ]] && dup=1; done
      [ "$dup" = 1 ] || chk_err "update.sh würde abbrechen: $msg"
    fi
  fi
  return 0
}

print_check() { # gibt Meldungen aus; Rückgabe 1 bei Fehlern
  local m
  for m in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do echo "FEHLER   $m"; done
  for m in ${CHK_WARN[@]+"${CHK_WARN[@]}"}; do echo "WARNUNG  $m"; done
  for m in ${CHK_NOTE[@]+"${CHK_NOTE[@]}"}; do echo "HINWEIS  $m"; done
  echo "Ergebnis: ${#CHK_ERR[@]} Fehler, ${#CHK_WARN[@]} Warnungen."
  [ "${#CHK_ERR[@]}" -eq 0 ]
}

# ---------------------------------------------------------------- Schreiben
declare -a NEW_LINES=()
TMPFILES=()
cleanup() { local f; for f in ${TMPFILES[@]+"${TMPFILES[@]}"}; do rm -f "$f"; done; }

build_new_lines() {
  local k i line last first
  NEW_LINES=(${ENV_LINES[@]+"${ENV_LINES[@]}"})
  for k in $(printf '%s\n' ${PEND_SET[@]+"${!PEND_SET[@]}"} | sort); do
    [ -n "$k" ] || continue
    if is_secretlike "$k"; then die "Interner Schutz: $k ist ein Geheimnis und wird nie in die Datei geschrieben."; fi
    last=-1; first=-1
    for i in "${!NEW_LINES[@]}"; do
      line="${NEW_LINES[$i]}"
      if [[ $line == "$k="* ]]; then last=$i
      elif [[ $line =~ ^#[[:space:]]*"$k"= ]] && [ "$first" = -1 ]; then first=$i; fi
    done
    if [ "$last" != -1 ]; then NEW_LINES[last]="$k=$(quote_value "${PEND_SET[$k]}")"
    elif [ "$first" != -1 ]; then NEW_LINES[first]="$k=$(quote_value "${PEND_SET[$k]}")"
    else NEW_LINES+=("$k=$(quote_value "${PEND_SET[$k]}")"); fi
  done
  for k in $(printf '%s\n' ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"} | sort); do
    [ -n "$k" ] || continue
    for i in "${!NEW_LINES[@]}"; do
      line="${NEW_LINES[$i]}"
      if [[ $line == "$k="* ]]; then
        # Ein Geheimnis wird gelöscht, nicht auskommentiert (es soll nicht als Kommentar lesbar bleiben).
        if is_masked "$k"; then NEW_LINES[i]=$'\x01DELETE'; else NEW_LINES[i]="# $line"; fi
      fi
    done
  done
  local -a kept=()
  for i in "${!NEW_LINES[@]}"; do [ "${NEW_LINES[$i]}" = $'\x01DELETE' ] || kept+=("${NEW_LINES[$i]}"); done
  NEW_LINES=(${kept[@]+"${kept[@]}"})
}

BACKUP_PATH=""
write_env() {
  [ "$ENV_EXISTS" = 1 ] || die "Env-Datei $ENV_FILE fehlt; zuerst setup.sh ausführen (Speichern würde das Setup überspringen)."
  [ ! -L "$ENV_FILE" ] || die "Env-Datei darf kein Symlink sein"
  [ ! -e "$ENV_FILE.deploy-lock" ] || die "Ein Rollout läuft (Sperre $ENV_FILE.deploy-lock); später erneut versuchen"
  build_new_lines
  local dir ts bak n tmp same=0
  if [ "${#NEW_LINES[@]}" -eq "${#ENV_LINES[@]}" ]; then
    same=1
    for n in "${!NEW_LINES[@]}"; do [ "${NEW_LINES[$n]}" = "${ENV_LINES[$n]}" ] || { same=0; break; }; done
  fi
  BACKUP_PATH=""
  if [ "$same" = 1 ]; then PEND_SET=(); PEND_UNSET=(); return 0; fi
  dir="$(dirname "$ENV_FILE")"
  ts="$(date +%Y%m%d-%H%M%S)"; bak="$ENV_FILE.bak.$ts"; n=1
  while [ -e "$bak" ]; do bak="$ENV_FILE.bak.$ts-$n"; n=$((n + 1)); done
  ( umask 077; cp -p "$ENV_FILE" "$bak" ); chmod 600 "$bak"
  BACKUP_PATH="$bak"
  tmp="$(umask 077; mktemp "$dir/.settings.XXXXXX")"
  TMPFILES+=("$tmp")
  if [ "${#NEW_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NEW_LINES[@]}" > "$tmp"; else : > "$tmp"; fi
  chmod 600 "$tmp"
  chown --reference="$ENV_FILE" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$ENV_FILE"
  PEND_SET=(); PEND_UNSET=()
  env_load
}

show_val() { # Wert für die Anzeige (Geheimnisse nie)
  local k="$1" v="$2"
  if is_masked "$k"; then if [ -n "$v" ]; then printf '***'; else printf '(leer)'; fi; elif [ -z "$v" ]; then printf '(leer)'; else printf '%s' "$v"; fi
}
redact_line() { # eine Datei-Zeile ohne Geheimnisse ausgeben
  local line="$1"
  if [[ $line =~ ^[[:space:]]*#?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && { [[ $SECRET_ENV_KEYS == *" ${BASH_REMATCH[1]} "* ]] || is_masked "${BASH_REMATCH[1]}"; }; then
    printf '%s=***' "${BASH_REMATCH[1]}"
  else printf '%s' "$line"; fi
}

# ---------------------------------------------------------------- Menü (whiptail)
UI=""; ROWS=24; COLS=80; H=22; W=76; LH=12
WT_OUT=""

ui_init() {
  if command -v whiptail >/dev/null 2>&1; then UI=whiptail
  elif command -v dialog >/dev/null 2>&1; then UI=dialog
  else
    cat >&2 <<'EOF'
whiptail (oder dialog) fehlt; das Menü ist nicht verfügbar. Installieren mit: apt install whiptail
Ohne Menü funktionieren: --list, --get KEY, --set KEY=VALUE, --unset KEY, --check, --help
EOF
    exit 1
  fi
}
ui_size() {
  local sz
  if [ -n "${SETTINGS_ROWS:-}" ] && [ -n "${SETTINGS_COLS:-}" ]; then ROWS="$SETTINGS_ROWS"; COLS="$SETTINGS_COLS"
  elif sz="$(stty size 2>/dev/null </dev/tty)" && [ -n "$sz" ]; then ROWS="${sz% *}"; COLS="${sz#* }"
  else ROWS="${LINES:-$(tput lines 2>/dev/null || echo 24)}"; COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"; fi
  [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24; [[ $COLS =~ ^[0-9]+$ ]] || COLS=80
  H=$((ROWS - 2)); [ "$H" -gt 30 ] && H=30; [ "$H" -lt 14 ] && H=14
  W=$((COLS - 4)); [ "$W" -gt 100 ] && W=100; [ "$W" -lt 50 ] && W=50
  LH=$((H - 8)); [ "$LH" -lt 4 ] && LH=4
  return 0
}
# whiptail aufrufen; Auswahl landet in WT_OUT, Rückgabe = Exit-Code. @H, @W, @LH werden durch die aktuelle Fenstergröße ersetzt.
wt() {
  local rc=0 a bt="$BACKTITLE | ${ENV_FILE##*/}"
  local -a args=()
  ui_size
  [ "$(pending_count)" -eq 0 ] || bt+=" | $(pending_count) ungespeichert"
  for a in "$@"; do
    case "$a" in @H) a="$H" ;; @W) a="$W" ;; @LH) a="$LH" ;; *) ;; esac
    args+=("$a")
  done
  WT_OUT="$("$UI" --backtitle "$bt" --ok-button OK --cancel-button Zurück --yes-button Ja --no-button Nein "${args[@]}" 3>&1 1>&2 2>&3)" || rc=$?
  return "$rc"
}
FIT_H=20; FIT_LH=10
fit_menu() { # Einträge Textzeilen
  ui_size
  FIT_LH="$1"; [ "$FIT_LH" -le "$LH" ] || FIT_LH="$LH"
  FIT_H=$((FIT_LH + $2 + 6)); [ "$FIT_H" -le "$H" ] || FIT_H="$H"
  return 0
}
text_height() { # Zeilen eines Textes (mit Umbruch) + Rahmen
  local text="$1" lines=0 line
  ui_size
  while IFS= read -r line; do lines=$((lines + 1 + ${#line} / (W - 6))); done <<< "$text"
  echo $((lines + 6))
}
fit_menu_text() { local th; th="$(text_height "$2")"; fit_menu "$1" $((th - 5)); }
ui_msg() { # Titel Text
  local h st="" t="$1"; ui_size; h="$(text_height "$2")"
  if [ "$h" -gt "$H" ]; then h=$H; st=--scrolltext; t+=" (Tab, dann Enter schließt)"; fi
  wt --title "$t" ${st:+"$st"} --msgbox "$2" "$h" "$W" || true
}
ui_yesno() { # Titel Text [--defaultno]
  local h; ui_size; h="$(text_height "$2")"; [ "$h" -gt "$H" ] && h=$H
  wt --title "$1" ${3:+"$3"} --yesno "$2" "$h" "$W"
}
ui_input() { # Titel Text Startwert
  local h; ui_size; h="$(text_height "$2")"; h=$((h + 2)); [ "$h" -gt "$H" ] && h=$H
  if [ "${UI_PASSWORD:-0}" = 1 ]; then wt --title "$1" --passwordbox "$2" "$h" "$W"; else wt --title "$1" --inputbox "$2" "$h" "$W" "$3"; fi
}
ui_textfile() { # Titel Datei
  local text h; text="$(cat "$2")"; ui_size; h="$(text_height "$text")"
  if [ "$h" -le "$H" ]; then wt --title "$1" --msgbox "$text" "$h" "$W" || true
  else wt --title "$1 (Esc schließt)" --scrolltext --textbox "$2" @H @W || true; fi
}

MENU_TITLES=("Pflichtangaben" "Hosts und Listener" "Datenbank" "Mail, Missbrauch, Limits" "Webhooks, MCP, Ingest, OAuth" "Umstieg, Speicher, Verwaltung" "Image" "Rollout, Netz, Veröffentlichung" "Replikate und Ressourcen" "Update und Health" "Secrets (nur Namen und Pfade)" "Dateivarianten (_FILE)" "Sonstiges")
MENU_TG=("" "Hosts|Listener" "Datenbank" "Missbrauchsschutz|Limits|Mail-Netze" "Webhook-Limits|MCP-Token-Ratelimit|Ingest-Ratelimit|MCP-OAuth" "Umstieg|Speicher|Verwaltung" "Image" "Rollout|Veröffentlichung" "Replikate und Platzierung|Ressourcen" "Update und Health" "Secrets" "Dateivarianten" "")
# Pflichtangaben: Mindestsatz, damit die Installation das alte Backend vollständig ersetzen kann (Domain/Passkeys, externe
# Datenbank, Veröffentlichung der beiden Listener, Reverse Proxy, Umstieg aus dem Altsystem). Geheimnisse fragt setup.sh ab.
REQUIRED_KEYS="FORM_ADMIN_ORIGIN FORM_RP_ID FORM_DB_HOST FORM_DB_PORT FORM_DB_USER FORM_DB_NAME FORM_DB_TLS PUBLISHED_PORT FORM_PUBLISH_PORT FORM_PUBLIC_PUBLISH_PORT BIND_ADDR FORM_TRUSTED_PROXIES FORM_MIGRATION_ALLOWED_NETS FORM_IMAGE_TAG"
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) CRUMB_SEP=" › " ;; *) CRUMB_SEP=" > " ;; esac
crumb() { local out="Einstellungen" p; for p in "$@"; do out+="$CRUMB_SEP$p"; done; printf '%s' "$out"; }

declare -a GROUP_KEYS=()
build_groups() {
  local idx k tg n=$((${#MENU_TITLES[@]} - 1))
  local -a tgs
  declare -A seen=()
  GROUP_KEYS=()
  for idx in "${!MENU_TITLES[@]}"; do
    GROUP_KEYS[idx]=""
    [ "$idx" -lt "$n" ] || continue
    IFS='|' read -ra tgs <<< "${MENU_TG[$idx]}"
    for tg in "${tgs[@]}"; do
      for k in "${KEYS[@]}"; do
        if [ "${T_GROUP[$k]}" = "$tg" ] && [ -z "${seen[$k]+x}" ]; then GROUP_KEYS[idx]+="${GROUP_KEYS[idx]:+ }$k"; seen[$k]=1; fi
      done
    done
  done
  for k in "${KEYS[@]}"; do [ -n "${seen[$k]+x}" ] || GROUP_KEYS[n]+="${GROUP_KEYS[n]:+ }$k"; done
  # Pflichtangaben (Index 0) sind eine zusätzliche Sicht auf Variablen, die auch in ihrer Fachgruppe stehen.
  for k in $REQUIRED_KEYS; do is_known "$k" && GROUP_KEYS[0]+="${GROUP_KEYS[0]:+ }$k"; done
}
group_summary() { # Index -> "n Einträge, m gesetzt[, c geändert]"
  local n=0 m=0 c=0 k
  for k in ${GROUP_KEYS[$1]}; do
    n=$((n + 1)); is_set "$k" && m=$((m + 1))
    if [ -n "${PEND_SET[$k]+x}" ] || [ -n "${PEND_UNSET[$k]+x}" ]; then c=$((c + 1)); fi
  done
  if [ "$c" -gt 0 ]; then echo "$n Einträge, $m gesetzt, $c geändert"; else echo "$n Einträge, $m gesetzt"; fi
}
state_label() {
  local k="$1"
  if [ -n "${PEND_UNSET[$k]+x}" ]; then echo RESET
  elif [ -n "${PEND_SET[$k]+x}" ]; then echo NEU
  elif in_file "$k"; then echo gesetzt
  else echo Default; fi
}
item_desc() { # KEY Breite -> "Wert  Zustand  Wirkung" (Wert wird auf die Breite gekürzt)
  local k="$1" dw="${2:-34}" v u vb
  if [ "${T_SECRET[$k]}" = 1 ]; then printf 'Geheimnis (nicht in der Datei)'; return; fi
  v="$(eff_value "$k")"; u="${T_UNIT[$k]}"
  if is_masked "$k" && [ -n "$v" ]; then v="***"; fi
  if [ "$dw" -ge 32 ]; then vb=$((dw - 19)); elif [ "$dw" -ge 20 ]; then vb=$((dw - 9)); else vb=$dw; fi
  [ "$vb" -ge 6 ] || vb=6; [ "$vb" -le 26 ] || vb=26
  if [ -z "$v" ]; then v="(leer)"; elif [ -n "$u" ] && [ $((${#v} + ${#u} + 1)) -le "$vb" ]; then v="$v $u"; fi
  if [ "${#v}" -gt "$vb" ]; then v="${v:0:$((vb - 1))}~"; fi
  if [ "$dw" -ge 32 ]; then printf '%-*s %-8s %s' "$vb" "$v" "$(state_label "$k")" "$(apply_label "$k")"
  elif [ "$dw" -ge 20 ]; then printf '%-*s %s' "$vb" "$v" "$(state_label "$k")"
  else printf '%s' "$v"; fi
}
detail_text() { # KEY
  local k="$1"
  printf '%s\n\nTyp:      %s\nDefault:  %s\nAktuell:  %s (%s)\nWirkung:  %s' \
    "${T_SUM[$k]}" "$(describe_type "$k")" "$(show_val "$k" "$(default_of "$k")")" "$(show_val "$k" "$(eff_value "$k")")" "$(state_label "$k")" "$(effect_text "$k")"
}

info_text() { # KEY -> Erklärung (lang, falls vorhanden) plus Typ, Default, aktueller Wert
  local k="$1" h="${T_HELP[$1]:-}"
  [ -n "$h" ] || h="${T_SUM[$k]}"
  printf '%s\n\nTyp:      %s\nDefault:  %s\nAktuell:  %s (%s)\nWirkung:  %s' \
    "$h" "$(describe_type "$k")" "$(show_val "$k" "$(default_of "$k")")" "$(show_val "$k" "$(eff_value "$k")")" "$(state_label "$k")" "$(effect_text "$k")"
}
PARENT_CRUMB=""
reset_key() {
  local k="$1"
  if ! in_file "$k" && [ -z "${PEND_SET[$k]+x}" ]; then
    ui_msg "$k" "Nicht gesetzt: es gilt bereits der Default ($(default_of "$k"))."
    return 0
  fi
  queue_unset "$k"
  if [ -n "${PEND_SET[$k]+x}" ]; then unset 'PEND_SET[$k]'; fi
}
edit_key() { # KEY
  local k="$1" base="${T_TYPE[$1]%%:*}" init prompt tok n lo hi ct i choice def
  local -a opts=() ch
  ct="$(crumb ${PARENT_CRUMB:+"$PARENT_CRUMB"} "$k")"
  if [ "${T_SECRET[$k]}" = 1 ]; then ui_msg "$ct" "$(secret_hint "$k")"; return 0; fi
  [ -z "${T_HELP[$k]:-}" ] || ui_msg "$ct: Erklärung" "$(info_text "$k")"
  init="$(eff_value "$k")"; lo="${T_MIN[$k]}"
  UI_PASSWORD=0; if [[ $PLAIN_SECRETS == *" $k "* ]]; then UI_PASSWORD=1; init=""; fi; hi="${T_MAX[$k]}"; def="$(default_of "$k")"
  case "$base" in
    bool) opts=(true "an" false "aus") ;;
    choice) IFS='|' read -ra ch <<< "${T_CHOICES[$k]}"; for tok in "${ch[@]}"; do opts+=("$tok" ""); done
      [ -n "$def" ] || opts+=("''" "leer (explizit gesetzt)") ;;
    int) if [[ $lo =~ ^[0-9]+$ && $hi =~ ^[0-9]+$ ]] && [ $((hi - lo)) -le 5 ]; then for ((i = lo; i <= hi; i++)); do opts+=("$i" ""); done; fi ;;
  esac
  if [ "${#opts[@]}" -gt 0 ]; then
    n=$(( ${#opts[@]} / 2 ))
    if in_file "$k" || [ -n "${PEND_SET[$k]+x}" ]; then opts+=("-" "Auf Default zurücksetzen (${def:-leer})"); n=$((n + 1)); fi
    for ((i = 0; i < ${#opts[@]}; i += 2)); do [ "${opts[i]}" = "$init" ] && opts[i + 1]="${opts[i + 1]:+${opts[i + 1]}  }<- aktuell"; done
    prompt="$(detail_text "$k")"
    fit_menu_text "$n" "$prompt"
    if wt --title "$ct" --default-item "$init" --menu "$prompt" "$FIT_H" @W "$FIT_LH" "${opts[@]}"; then
      choice="$WT_OUT"
      if [ "$choice" = "''" ]; then choice=""; fi
      if [ "$choice" = "$init" ] && ! { [ -z "$init" ] && ! in_file "$k" && [ -z "${PEND_SET[$k]+x}" ]; }; then :
      elif [ "$choice" = - ]; then reset_key "$k"
      else queue_set "$k" "$choice"; fi
    fi
    return 0
  fi
  prompt="$(detail_text "$k")"$'\n\n'"Neuer Wert (leer lassen = Default${def:+ $def}"
  if [ -z "$def" ] || [[ ${T_TYPE[$k]} == *\? ]]; then prompt+="; \"\" setzt den Wert explizit auf leer"; fi
  prompt+="):"
  while :; do
    ui_input "$ct" "$prompt" "$init" || return 0
    tok="${WT_OUT#"${WT_OUT%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"
    if [ -z "$tok" ]; then
      if in_file "$k" || [ -n "${PEND_SET[$k]+x}" ]; then
        if ui_yesno "$ct" "Leer: $k auf den Default zurücksetzen (${def:-leer})?
Die Zeile in der Datei wird beim Speichern auskommentiert."; then reset_key "$k"; return 0; fi
        init="$(eff_value "$k")"; continue
      fi
      ui_msg "$ct" "Nicht gesetzt: es gilt bereits der Default (${def:-leer})."; return 0
    fi
    if [ "$tok" = '""' ]; then tok=""; fi
    if validate "$k" "$tok"; then
      if [ "$tok" != "$(eff_value "$k")" ] || in_file "$k" || [ -n "${PEND_SET[$k]+x}" ] || [ -z "$tok" ]; then queue_set "$k" "$tok"; fi
      return 0
    fi
    init="$WT_OUT"
    ui_msg "Ungültiger Wert" "$k: $V_ERR

Erlaubt: $(describe_type "$k")
Die Eingabe bleibt im Feld stehen und kann korrigiert werden."
  done
}

declare -A GSEL=()
longest_key() { local k m=0; for k in "$@"; do [ "${#k}" -le "$m" ] || m=${#k}; done; echo "$m"; }
group_menu() { # Index
  local idx="$1" k kw dw intro title
  local -a items keys
  title="${MENU_TITLES[$idx]}"
  read -ra keys <<< "${GROUP_KEYS[$idx]}"
  [ "${#keys[@]}" -gt 0 ] || return 0
  kw="$(longest_key "${keys[@]}")"
  PARENT_CRUMB="$title"
  while :; do
    ui_size; dw=$((W - kw - 9))
    items=()
    for k in "${keys[@]}"; do items+=("$k" "$(item_desc "$k" "$dw")"); done
    intro="Enter: bearbeiten, Esc: zurück. Spalten: Wert | Zustand | Wirkung"
    if [ "$idx" -eq 0 ]; then intro="Mindestangaben für den Ersatz des alten Backends (Passwörter und Server-Key fragt setup.sh ab). "$intro; fi
    fit_menu "${#keys[@]}" 1
    if wt --title "$(crumb "$title")" ${GSEL[$idx]:+--default-item "${GSEL[$idx]}"} --menu "$intro" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      GSEL[$idx]="$WT_OUT"; edit_key "$WT_OUT"
    else return 0; fi
  done
}
search_menu() {
  local term="" k hay lt sel="" kw dw
  local -a items keys
  while :; do
    ui_input "$(crumb Suche)" "Suchbegriff (Name, Beschreibung, Gruppe oder Zustand wie gesetzt/neu):" "$term" || return 0
    term="${WT_OUT,,}"; term="${term#"${term%%[![:space:]]*}"}"; term="${term%"${term##*[![:space:]]}"}"
    [ -n "$term" ] || { ui_msg "$(crumb Suche)" "Bitte einen Suchbegriff eingeben."; continue; }
    sel=""
    while :; do
      items=(); keys=()
      for k in "${KEYS[@]}"; do
        hay="${k,,} ${T_SUM[$k],,} ${T_GROUP[$k],,} $(state_label "$k" | tr '[:upper:]' '[:lower:]')"
        if [[ $hay == *"$term"* ]]; then keys+=("$k"); fi
      done
      if [ "${#keys[@]}" -eq 0 ]; then ui_msg "$(crumb Suche)" "Keine Treffer für '$term'."; break; fi
      kw="$(longest_key "${keys[@]}")"; ui_size; dw=$((W - kw - 9))
      for k in "${keys[@]}"; do items+=("$k" "$(item_desc "$k" "$dw")"); done
      lt=${#keys[@]}
      fit_menu "$lt" 1
      PARENT_CRUMB="Suche"
      if wt --title "$(crumb Suche "'$term'")" ${sel:+--default-item "$sel"} --menu "$lt Treffer. Enter: bearbeiten, Esc: neue Suche" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
        sel="$WT_OUT"; edit_key "$sel"
      else break; fi
    done
  done
}
show_notes() {
  ui_msg "$(crumb Hinweise)" "Wirkung der Einstellungen
- live: Der Dienst übernimmt Werte aus dem Dashboard. Eine Variable in der Datei ist immer ENV, hat Vorrang und sperrt das Feld; sie wirkt nach einem Rollout (Jetzt anwenden).
- Neustart: wird beim Start der Dienste gelesen; wirkt nach einem Rollout.
- nur ENV: nur über die Datei, wirkt nach einem Rollout.

Speichern und Anwenden
- Änderungen sammelt das Menü im Speicher. Beim Speichern erscheint eine Übersicht mit Prüfung; vorher entsteht eine Sicherung <Datei>.bak.JJJJMMTT-HHMMSS.
- Zurücksetzen kommentiert die Zeile aus (# KEY=alt): reversibel, danach gilt der Default der Vorlage.
- Geheimnisse erscheinen hier nie und werden nie geschrieben.
- Ausgerollt wird nur mit \"Jetzt anwenden\" und Bestätigung (ruft update.sh)."
}

build_review() { # Datei
  local f="$1" k old new line m lbl before after
  {
    echo "ÄNDERUNGEN"
    for k in $(printf '%s\n' ${PEND_SET[@]+"${!PEND_SET[@]}"} ${PEND_UNSET[@]+"${!PEND_UNSET[@]}"} | sort -u); do
      [ -n "$k" ] || continue
      if in_file "$k"; then old="$(show_val "$k" "${ENV_VAL[$k]}")"; else old="(Default: $(show_val "$k" "$(default_of "$k")"))"; fi
      if [ -n "${PEND_SET[$k]+x}" ]; then new="$(show_val "$k" "${PEND_SET[$k]}")"; else new="(Default: $(show_val "$k" "$(default_of "$k")"), Zeile wird auskommentiert)"; fi
      lbl="$(apply_label "$k")"
      echo "  $k: $old  ->  $new   [$lbl]"
    done
    echo
    echo "WIRKUNG: erst nach \"Jetzt anwenden\" (update.sh: Migration, dann Rollout)."
    echo
    echo "DIFF der Datei $ENV_FILE (ohne Kontext)"
    before="$(mktemp)"; after="$(mktemp)"; TMPFILES+=("$before" "$after")
    if [ "${#ENV_LINES[@]}" -gt 0 ]; then printf '%s\n' "${ENV_LINES[@]}" > "$before"; fi
    build_new_lines
    if [ "${#NEW_LINES[@]}" -gt 0 ]; then printf '%s\n' "${NEW_LINES[@]}" > "$after"; fi
    diff -U0 "$before" "$after" | tail -n +3 | while IFS= read -r line; do
      case "$line" in
        '@@'*) ;;
        [+-]*) printf '%s%s\n' "${line:0:1}" "$(redact_line "${line:1}")" ;;
      esac
    done || true
    rm -f "$before" "$after"
    check_all
    if [ "${#CHK_ERR[@]}" -gt 0 ] || [ "${#CHK_WARN[@]}" -gt 0 ] || [ "${#CHK_NOTE[@]}" -gt 0 ]; then
      echo; echo "PRÜFUNG"
      for m in ${CHK_ERR[@]+"${CHK_ERR[@]}"}; do echo "  FEHLER   $m"; done
      for m in ${CHK_WARN[@]+"${CHK_WARN[@]}"}; do echo "  WARNUNG  $m"; done
      for m in ${CHK_NOTE[@]+"${CHK_NOTE[@]}"}; do echo "  HINWEIS  $m"; done
    fi
  } > "$f"
}
save_flow() { # Rückgabe 0 = gespeichert
  local f
  if [ "$(pending_count)" -eq 0 ]; then ui_msg "Speichern" "Keine Änderungen."; return 1; fi
  if [ "$ENV_EXISTS" = 0 ]; then ui_msg "Speichern" "Die Datei $ENV_FILE existiert nicht. Zuerst setup.sh ausführen."; return 1; fi
  f="$(mktemp)"; TMPFILES+=("$f")
  build_review "$f"
  ui_textfile "$(crumb "Änderungen prüfen")" "$f"
  if [ "${#CHK_ERR[@]}" -gt 0 ]; then
    ui_yesno "Fehler in der Prüfung" "Die Prüfung meldet ${#CHK_ERR[@]} Fehler (siehe Übersicht); update.sh würde abbrechen. Trotzdem speichern?" --defaultno || return 1
  elif ! ui_yesno "Speichern" "Änderungen in $ENV_FILE speichern?
Vorher wird eine Sicherung angelegt."; then
    return 1
  fi
  write_env
  ui_msg "$(crumb Gespeichert)" "${BACKUP_PATH:+Sicherung: $BACKUP_PATH
}Datei: $ENV_FILE

Die Dienste laufen noch mit den alten Werten. Wirksam wird die Änderung erst nach 'Jetzt anwenden' (oder update.sh)."
  return 0
}
apply_now() {
  local choice tag
  if [ "$(pending_count)" -gt 0 ]; then
    ui_yesno "Jetzt anwenden" "Es gibt ungespeicherte Änderungen. Zuerst speichern?" || return 0
    save_flow || return 0
  fi
  if [ ! -f "$ENV_FILE" ]; then ui_msg "Jetzt anwenden" "Es gibt noch keine Env-Datei; zuerst setup.sh ausführen."; return 0; fi
  check_all
  if [ "${#CHK_ERR[@]}" -gt 0 ]; then
    ui_msg "Jetzt anwenden" "Die Prüfung meldet Fehler; zuerst beheben (Menü oder --check):
$(printf '%s\n' "${CHK_ERR[@]}")"
    return 0
  fi
  [ -x "$MODE_DIR/update.sh" ] || { ui_msg "Jetzt anwenden" "$MODE_DIR/update.sh nicht gefunden."; return 0; }
  wt --title "$(crumb Anwenden)" --cancel-button Zurück --menu "Nichts wird ohne Bestätigung ausgerollt." @H @W 3 \
    A "Einstellungen ausrollen (Image/Digest bleibt, update.sh)" \
    T "Auf neues Image-Tag aktualisieren (update.sh --tag)" \
    D "Trockenlauf anzeigen (update.sh --dry-run, ändert nichts)" || return 0
  choice="$WT_OUT"
  case "$choice" in
    A)
      ui_yesno "Ausrollen bestätigen" "update.sh führt aus: Prüfung der externen Datenbank, einmalige Migration, danach Rollout der App mit den neuen Werten (${MODE}). Ist die Datenbank gesichert? Jetzt ausrollen?" --defaultno || return 0
      clear 2>/dev/null || true
      "$MODE_DIR/update.sh" --env-file "$ENV_FILE" || echo "update.sh endete mit einem Fehler."
      read -r -p "Enter zum Zurückkehren ... " _ || true
      env_load ;;
    T)
      ui_input "Image-Tag" "Neuer Image-Tag (z. B. eine Commit-SHA):" "" || return 0
      tag="${WT_OUT//[[:space:]]/}"
      if ! validate_text FORM_IMAGE_TAG "$tag" imagetag; then ui_msg "Ungültiger Tag" "$V_ERR"; return 0; fi
      ui_yesno "Ausrollen bestätigen" "update.sh --tag $tag: Tag wird zu einem Digest aufgelöst, dann Migration und Rollout. Ist die Datenbank gesichert? Jetzt ausrollen?" --defaultno || return 0
      clear 2>/dev/null || true
      "$MODE_DIR/update.sh" --env-file "$ENV_FILE" --tag "$tag" || echo "update.sh endete mit einem Fehler."
      read -r -p "Enter zum Zurückkehren ... " _ || true
      env_load ;;
    D)
      clear 2>/dev/null || true
      "$MODE_DIR/update.sh" --env-file "$ENV_FILE" --dry-run || echo "update.sh --dry-run endete mit einem Fehler."
      read -r -p "Enter zum Zurückkehren ... " _ || true ;;
  esac
}
leave_menu() { # Rückgabe 0 = beenden
  local choice
  if [ "$(pending_count)" -eq 0 ]; then return 0; fi
  if wt --title "$(crumb Beenden)" --cancel-button "Zurück zum Menü" --menu "$(pending_count) Änderung(en) sind nicht gespeichert." @H @W 3 \
      S "Speichern und beenden" V "Verwerfen und beenden" Z "Zurück zum Menü"; then choice="$WT_OUT"; else return 1; fi
  case "$choice" in
    S) save_flow && return 0 || return 1 ;;
    V) return 0 ;;
    *) return 1 ;;
  esac
}
main_menu() {
  local sel="" i t d dw
  local -a items
  ui_size
  if [ "$ENV_EXISTS" = 0 ]; then ui_msg "Hinweis" "Die Datei $ENV_FILE existiert noch nicht. Sie können Werte ansehen; Speichern und Anwenden gehen erst nach setup.sh."; fi
  while :; do
    ui_size; dw=$((W - 36 - 9))
    items=()
    for i in "${!MENU_TITLES[@]}"; do
      [ -n "${GROUP_KEYS[$i]}" ] || continue
      d="($(group_summary "$i"))"
      if [ "${#d}" -gt "$dw" ]; then d="${d/ Einträge/}"; d="${d/ gesetzt/ ges.}"; fi
      items+=("${MENU_TITLES[$i]}" "${d:0:dw}")
    done
    d="Prüfen, speichern ($(pending_count) offen)"
    items+=("Suchen" "Filtern nach Text" "Hinweise" "live / Neustart / nur ENV" "Speichern" "${d:0:dw}" "Anwenden" "Ausrollen (mit Bestätigung)")
    t="Gruppe wählen (Enter), Esc beendet."
    if [ "$ROWS" -lt 24 ] || [ "$COLS" -lt 80 ]; then t+=$'\n'"Terminal ${COLS}x${ROWS}: empfohlen 80x24 oder größer."; fi
    fit_menu $(( ${#items[@]} / 2 )) "$(grep -c '' <<< "$t")"
    if wt --title "$(crumb)" --cancel-button Beenden ${sel:+--default-item "$sel"} --menu "$t" "$FIT_H" @W "$FIT_LH" "${items[@]}"; then
      sel="$WT_OUT"
      case "$sel" in
        Suchen) search_menu ;;
        Hinweise) show_notes ;;
        Speichern) save_flow || true ;;
        Anwenden) apply_now ;;
        *) for i in "${!MENU_TITLES[@]}"; do if [ "${MENU_TITLES[$i]}" = "$sel" ]; then group_menu "$i"; break; fi; done ;;
      esac
    else
      if leave_menu; then return 0; fi
    fi
  done
}

# ---------------------------------------------------------------- Kommandozeile
usage() { sed -n "4,15p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cli_list() {
  local k v src extra
  printf '%-38s %-26s %-18s %s\n' VARIABLE WERT DEFAULT QUELLE
  for k in "${KEYS[@]}"; do
    # *_FILE-Varianten nur zeigen, wenn sie in der Datei stehen
    if [ "${T_GROUP[$k]}" = Dateivarianten ] && ! in_file "$k" && [ -z "${PEND_SET[$k]+x}" ]; then continue; fi
    if [ "${T_SECRET[$k]}" = 1 ]; then
      printf '%-38s %-26s %-18s %s\n' "$k" "(Secret)" "-" "Docker-Secret"
      continue
    fi
    v="$(eff_value "$k")"
    if is_masked "$k" && [ -n "$v" ]; then v="***"; fi
    if in_file "$k"; then src="Datei"; else src="Default"; fi
    printf '%-38s %-26s %-18s %s\n' "$k" "${v:-(leer)}" "$(default_of "$k")" "$src"
  done
  for k in $(printf '%s\n' ${ENV_VAL[@]+"${!ENV_VAL[@]}"} | sort); do
    [ -n "$k" ] || continue
    if is_known "$k"; then continue; fi
    if is_secretlike "$k" || [[ $SECRET_ENV_KEYS == *" $k "* ]]; then extra="***"; else extra="${ENV_VAL[$k]:-(leer)}"; fi
    printf '%-38s %-26s %-18s %s\n' "$k" "$extra" "-" "Datei (unbekannt)"
  done
}
cli_info() {
  local k="$1"
  if ! is_known "$k"; then echo "Unbekannte Variable: $k" >&2; return 2; fi
  printf '%s\n' "$k"; info_text "$k"; echo
}
cli_get() {
  local k="$1"
  if [[ $PLAIN_SECRETS == *" $k "* ]]; then echo "$k ist ein Geheimnis und wird nie ausgegeben." >&2; return 2; fi
  if [[ $SECRET_ENV_KEYS == *" $k "* ]] || { [ -n "${T_SECRET[$k]+x}" ] && [ "${T_SECRET[$k]}" = 1 ]; }; then
    echo "$k ist ein Geheimnis und wird nie ausgegeben." >&2; return 2
  fi
  if ! is_known "$k"; then
    if [ -n "${ENV_VAL[$k]+x}" ] && ! is_secretlike "$k"; then printf '%s\n' "${ENV_VAL[$k]}"; return 0; fi
    echo "Unbekannte Variable: $k" >&2; return 2
  fi
  eff_value "$k"; echo
}
cli_set() { # KEY=VALUE
  local pair="$1" k v
  if ! [[ $pair == ?*=* ]]; then echo "Format: --set KEY=VALUE" >&2; return 64; fi
  k="${pair%%=*}"; v="${pair#*=}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ $SECRET_ENV_KEYS == *" $k "* ]] || { [ -n "${T_SECRET[$k]+x}" ] && [ "${T_SECRET[$k]}" = 1 ]; }; then
    echo "$k ist ein Geheimnis und wird nie in die Datei geschrieben." >&2; secret_hint "$k" >&2; echo >&2; return 2
  fi
  if ! is_known "$k"; then
    if is_secretlike "$k"; then echo "$k sieht wie ein Geheimnis aus und wird nie geschrieben." >&2; return 2; fi
    echo "Unbekannte Variable: $k (nicht in der Vorlage für $MODE; siehe --list)" >&2; return 2
  fi
  if ! validate "$k" "$v"; then echo "Ungültiger Wert für $k: $V_ERR" >&2; return 3; fi
  queue_set "$k" "$v"
  echo "$k gesetzt auf: $(show_val "$k" "$v")"
  case "${T_APPLY[$k]}" in live|restart) echo "Hinweis: $k ist eine Server-Einstellung; ein Wert in der Datei hat Vorrang vor dem Dashboard und sperrt dort das Feld." ;; esac
}
cli_unset() {
  local k="$1"
  if ! is_known "$k" && [ -z "${ENV_COUNT[$k]+x}" ]; then echo "Unbekannte Variable: $k" >&2; return 2; fi
  if ! in_file "$k"; then echo "$k ist nicht gesetzt (Default)."; return 0; fi
  queue_unset "$k"
  if is_masked "$k" || [[ $SECRET_ENV_KEYS == *" $k "* ]]; then echo "$k wird aus der Datei gelöscht (Zeile wird entfernt, nicht auskommentiert)."
  else echo "$k wird auf den Default zurückgesetzt (Zeile auskommentiert)."; fi
}

main() {
  local -a actions=()
  local want_menu=1 rc=0 act before="" after="" line
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) ENV_FILE="${2:?--env braucht einen Pfad}"; shift 2 ;;
      --list) actions+=("list"); want_menu=0; shift ;;
      --get) actions+=("get:${2:?--get braucht einen Namen}"); want_menu=0; shift 2 ;;
      --set) actions+=("set:${2:?--set braucht KEY=VALUE}"); want_menu=0; shift 2 ;;
      --unset) actions+=("unset:${2:?--unset braucht einen Namen}"); want_menu=0; shift 2 ;;
      --info) actions+=("info:${2:?--info braucht einen Namen}"); want_menu=0; shift 2 ;;
      --check) actions+=("check"); want_menu=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
    esac
  done
  [ -n "$ENV_FILE" ] || ENV_FILE="$DEFAULT_ENV"
  [[ $ENV_FILE == /* ]] || ENV_FILE="$PWD/$ENV_FILE"
  [ -d "$(dirname "$ENV_FILE")" ] || die "Verzeichnis der Env-Datei fehlt: $(dirname "$ENV_FILE")"
  load_tables
  env_load
  trap cleanup EXIT

  if [ "$want_menu" = 1 ]; then
    ui_init
    build_groups
    main_menu
    return 0
  fi

  local mutate=0
  for act in "${actions[@]}"; do case "$act" in set:*|unset:*) mutate=1 ;; esac; done
  if [ "$mutate" = 1 ]; then check_all; before="$(print_check || true)"; fi
  for act in "${actions[@]}"; do
    case "$act" in
      list) cli_list ;;
      get:*) cli_get "${act#get:}" || rc=$? ;;
      info:*) cli_info "${act#info:}" || rc=$? ;;
      set:*) cli_set "${act#set:}" || { rc=$?; break; } ;;
      unset:*) cli_unset "${act#unset:}" || { rc=$?; break; } ;;
      check) check_all; print_check || rc=1 ;;
    esac
  done
  if [ "$rc" != 0 ]; then PEND_SET=(); PEND_UNSET=(); return "$rc"; fi
  if [ "$(pending_count)" -gt 0 ]; then
    check_all; after="$(print_check || true)"
    # Neue Fehler (gegenüber dem Zustand vorher) verhindern das Speichern: update.sh würde abbrechen.
    local new_err=""
    while IFS= read -r line; do
      case "$line" in FEHLER*) [[ $before == *"$line"* ]] || new_err+="$line"$'\n' ;; esac
    done <<< "$after"
    if [ -n "$new_err" ]; then
      printf '%s' "$new_err" >&2
      echo "Nicht gespeichert: die Änderung würde einen Fehler erzeugen. Zusammengehörige Werte in einem Aufruf setzen (mehrere --set)." >&2
      return 3
    fi
    write_env
    if [ -n "$BACKUP_PATH" ]; then
      echo "Sicherung: $BACKUP_PATH"
      echo "Gespeichert: $ENV_FILE (wirksam nach dem nächsten Rollout: update.sh)"
    else
      echo "Unverändert: $ENV_FILE"
    fi
    while IFS= read -r line; do
      case "$line" in Ergebnis:*|'') continue ;; esac
      [[ $before == *"$line"* ]] || echo "$line"
    done <<< "$after"
  fi
  return 0
}

# Beim Einbinden per `source` (Tests) wird nicht gestartet.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
