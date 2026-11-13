#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Local image build and smoke test (no registry push, no deploy).
#   scripts/docker-build.sh [--no-smoke] [--keep] [--help]
# Builds the PWA if needed, builds form-backend:<commit>[-dirty] and form-backend:latest for the native architecture, runs the
# smoke test against a throw-away MariaDB and removes old form-backend:<hash> tags. Details: docs/ENTWICKLUNG.md, "Lokales Image".
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
: "${IMAGE_REPO:=form-backend}" "${KEEP_RECENT:=3}" "${MARIADB_IMAGE:=mariadb:lts}"
BUILD_LABEL='form-backend.local-build=1'
SMOKE_PREFIX=fbsmoke

usage() {
  cat <<'EOF'
Verwendung: scripts/docker-build.sh [Optionen]

Baut das Image lokal (native Architektur) aus dem aktuellen Checkout und prueft es.
  1. PWA bauen (npm ci / npm run build in pwa/), wenn pwa/dist fehlt oder aelter als die Quellen ist
  2. docker build -f backend/Dockerfile (Kontext Repo-Wurzel), Tags form-backend:<Commit> (+ -dirty bei
     ungesichertem Arbeitsbaum) und form-backend:latest
  3. Smoke-Test gegen eine echte Wegwerf-MariaDB (privates Netz): migrate, serve, /healthz, /ready,
     PWA-Index mit CSP, Kernpfad (Passkey-Login, Kunde, Kundenschluessel, Formular, Release, SDK-Zugang,
     Einsendung ueber die oeffentliche Ingest-Route, Pruefung in der DB: nur Chiffretext)
  4. Aufraeumen: Container/Netz/Temp-Dateien immer; alte form-backend:<Hash>-Tags bis auf die neuesten 3
     (und :latest) und dangling Schichten dieses Builds

Optionen:
  --no-smoke       nur bauen, kein Smoke-Test
  --keep           Smoke-Container und -Netz nicht entfernen (zum Untersuchen; Namen werden ausgegeben)
  --smoke-image R  nur den Smoke-Test gegen das vorhandene Image R ausfuehren (kein Build, kein Prune)
  -h, --help       diese Hilfe

Umgebung: IMAGE_REPO (form-backend), KEEP_RECENT (3), MARIADB_IMAGE (mariadb:lts).
Kein Push in eine Registry, kein Deploy. Exit 0 = ok, 1 = Pruefung fehlgeschlagen, 2 = Umgebungsproblem.
EOF
}

log() { printf '%s\n' "$*"; }
env_fail() { printf 'ENV: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- image helpers

# Newest-first list of <repo> tags that are not :latest (by image creation time, then tag).
list_hash_tags() {
  local repo=$1 tag created
  docker image ls "$repo" --format '{{.Tag}}' | while read -r tag; do
    [[ -n "$tag" && "$tag" != latest && "$tag" != '<none>' ]] || continue
    created=$(docker image inspect --format '{{.Created}}' "$repo:$tag")
    printf '%s %s\n' "$created" "$tag"
  done | sort -r | awk '{print $2}'
}

# Removes all <repo>:<tag> except :latest and the newest KEEP_RECENT hash tags. Images in use are kept (warning).
prune_old_images() {
  local repo=$1 keep=$2 n=0 tag removed=0
  while read -r tag; do
    [[ -n "$tag" ]] || continue
    n=$((n + 1))
    (( n > keep )) || continue
    if docker rmi "$repo:$tag" >/dev/null 2>&1; then removed=$((removed + 1)); log "alt entfernt: $repo:$tag"
    else log "WARN: $repo:$tag konnte nicht entfernt werden (in Benutzung?)"; fi
  done < <(list_hash_tags "$repo")
  log "Aufraeumen: $removed alte Tags entfernt, neueste $keep und :latest bleiben"
}

# ---------------------------------------------------------------- PWA

pwa_needs_build() {
  local dist=$REPO_ROOT/pwa/dist/index.html
  [[ -f "$dist" ]] || return 0
  [[ -n "$(find "$REPO_ROOT/pwa/src" "$REPO_ROOT/pwa/public" "$REPO_ROOT/pwa/index.html" "$REPO_ROOT/pwa/package.json" \
      "$REPO_ROOT/pwa/package-lock.json" "$REPO_ROOT/pwa/vite.config.ts" "$REPO_ROOT/pwa/svelte.config.js" "$REPO_ROOT/pwa/tsconfig.json" \
      -type f -newer "$dist" -print -quit 2>/dev/null)" ]]
}

build_pwa() {
  if pwa_needs_build; then
    command -v npm >/dev/null || env_fail 'npm fehlt (PWA muss gebaut werden)'
    log "PWA: baue pwa/dist"
    ( cd "$REPO_ROOT/pwa"
      if [[ ! -d node_modules || package-lock.json -nt node_modules/.package-lock.json ]]; then npm ci --no-audit --no-fund; fi
      npm run build )
  else
    log "PWA: pwa/dist ist aktuell"
  fi
}

# ---------------------------------------------------------------- smoke test

SMOKE_RUN=""; SMOKE_WORK=""; SMOKE_KEEP=0
smoke_cleanup() {
  local rc=$?
  if [[ -n "$SMOKE_RUN" && "$SMOKE_KEEP" != 1 ]]; then
    docker rm -f "$SMOKE_RUN-app" "$SMOKE_RUN-db" >/dev/null 2>&1 || true
    docker network rm "$SMOKE_RUN" >/dev/null 2>&1 || true
  elif [[ -n "$SMOKE_RUN" ]]; then
    log "--keep: Container $SMOKE_RUN-app / $SMOKE_RUN-db und Netz $SMOKE_RUN bleiben (docker rm -f ...; docker network rm $SMOKE_RUN)"
  fi
  [[ -z "$SMOKE_WORK" ]] || rm -rf "$SMOKE_WORK"
  trap - EXIT
  exit "$rc"
}

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

SMOKE_FAIL=0
check() {  # name got want
  if [[ "$2" == "$3" ]]; then log "ok   $1"; else log "FAIL $1 (got '$2', want '$3')"; SMOKE_FAIL=1; fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }

smoke_test() {
  local image=$1
  command -v curl >/dev/null && command -v python3 >/dev/null && command -v openssl >/dev/null || env_fail 'curl, python3 und openssl werden benoetigt'
  command -v php >/dev/null && php -r 'exit(extension_loaded("sodium")?0:1);' || env_fail 'PHP mit sodium wird fuer das SDK benoetigt'
  docker image inspect "$image" >/dev/null 2>&1 || env_fail "Image $image fehlt"
  SMOKE_RUN="$SMOKE_PREFIX-$$-$(openssl rand -hex 3)"
  trap smoke_cleanup EXIT
  umask 077
  SMOKE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/fbsmoke.XXXXXX")
  local pw key admin_port public_port origin
  pw=$(openssl rand -hex 16); key=$(openssl rand -hex 32)
  admin_port=$(free_port); public_port=$(free_port); origin="http://localhost:$admin_port"
  # Secrets only in a 0600 env file (not on a command line, never printed).
  { printf 'FORM_DB_PASSWORD=%s\nFORM_SERVER_KEY=%s\n' "$pw" "$key"
    printf 'FORM_DB_HOST=%s-db\nFORM_DB_USER=root\nFORM_DB_NAME=form\nFORM_DB_TLS=disable\nFORM_ALLOW_INSECURE_DEV=1\n' "$SMOKE_RUN"
    printf 'FORM_ADMIN_ORIGIN=%s\nFORM_RP_ID=localhost\nFORM_PUBLIC_PORT=8080\nFORM_INTERNAL_PORT=8081\n' "$origin"; } > "$SMOKE_WORK/app.env"

  log "Smoke: privates Netz $SMOKE_RUN, MariaDB ($MARIADB_IMAGE), Image $image"
  docker network create "$SMOKE_RUN" >/dev/null || env_fail 'Netz konnte nicht angelegt werden'
  docker run -d --name "$SMOKE_RUN-db" --network "$SMOKE_RUN" --tmpfs /var/lib/mysql -e MARIADB_ROOT_PASSWORD="$pw" -e MARIADB_DATABASE=form \
    "$MARIADB_IMAGE" >/dev/null || env_fail 'MariaDB konnte nicht gestartet werden'
  local up=0 i
  for i in $(seq 90); do
    if docker exec -e MYSQL_PWD="$pw" "$SMOKE_RUN-db" mariadb -uroot -e 'select 1' form >/dev/null 2>&1; then
      sleep 2
      docker exec -e MYSQL_PWD="$pw" "$SMOKE_RUN-db" mariadb -uroot -e 'select 1' form >/dev/null 2>&1 && { up=1; break; }
    fi
    sleep 1
  done
  (( up )) || env_fail 'MariaDB wurde nicht bereit'

  # Schema and migrations exactly as the entrypoint/CMD define them.
  if docker run --rm --network "$SMOKE_RUN" --env-file "$SMOKE_WORK/app.env" "$image" migrate >"$SMOKE_WORK/migrate.log" 2>&1; then log "ok   migrate (Exit 0)"
  else log "FAIL migrate"; tail -5 "$SMOKE_WORK/migrate.log" | cut -c1-200; return 1; fi
  docker run -d --name "$SMOKE_RUN-app" --network "$SMOKE_RUN" --env-file "$SMOKE_WORK/app.env" \
    -p "127.0.0.1:$admin_port:8081" -p "127.0.0.1:$public_port:8080" "$image" serve >/dev/null || { log 'FAIL serve konnte nicht gestartet werden'; return 1; }
  local admin="http://127.0.0.1:$admin_port" public="http://127.0.0.1:$public_port" up2=0
  for i in $(seq 60); do
    [[ "$(code "$admin/healthz")" == 200 ]] && { up2=1; break; }
    [[ "$(docker inspect -f '{{.State.Running}}' "$SMOKE_RUN-app")" == true ]] || break
    sleep 1
  done
  if (( ! up2 )); then log 'FAIL serve wurde nicht bereit'; docker logs "$SMOKE_RUN-app" 2>&1 | tail -8 | cut -c1-200; return 1; fi

  check "internal /healthz" "$(code "$admin/healthz")" 200
  check "internal /health" "$(code "$admin/health")" 200
  check "internal /ready (DB erreichbar)" "$(code "$admin/ready")" 200
  check "public /healthz" "$(code "$public/healthz")" 200
  check "healthz Koerper" "$(curl -s --max-time 10 "$admin/healthz" | tr -d ' \n')" '{"status":"ok"}'
  curl -s -D "$SMOKE_WORK/index.h" -o "$SMOKE_WORK/index.html" --max-time 10 "$admin/" || true
  check "PWA-Index: HTTP 200" "$(head -1 "$SMOKE_WORK/index.h" | tr -d '\r' | awk '{print $2}')" 200
  check "PWA-Index: HTML-Shell" "$(grep -ci '<div id="app"' "$SMOKE_WORK/index.html" || true)" 1
  check "PWA-Index: CSP default-src 'self'" "$(grep -ci "^content-security-policy: default-src 'self'" "$SMOKE_WORK/index.h" || true)" 1
  check "PWA: SPA-Fallback /login" "$(code "$admin/login")" 200
  check "Admin-API ohne Sitzung" "$(code "$admin/admin/api/v1/me")" 401
  check "oeffentlich: Admin-API fehlt" "$(code "$public/admin/api/v1/me")" 404

  # Core path: seed a synthetic account + passkey (the browser-side enrollment is not covered), then drive the real API.
  local flow=$SCRIPT_DIR/docker-smoke-flow.py
  python3 "$flow" seed "$SMOKE_WORK" > "$SMOKE_WORK/seed.sql"
  docker exec -i -e MYSQL_PWD="$pw" "$SMOKE_RUN-db" mariadb -uroot form < "$SMOKE_WORK/seed.sql" || { log 'FAIL Konto-Seed'; return 1; }
  local vars
  if vars=$(SMOKE_ADMIN_ORIGIN=$origin python3 "$flow" run "$SMOKE_WORK" 2> >(sed 's/^/     /' >&2)); then log "ok   Admin-Ablauf (Login, Kunde, Schluessel, Formular, Release, SDK-Zugang)"
  else log 'FAIL Admin-Ablauf'; return 1; fi
  local tenant form marker rid
  tenant=$(sed -n 's/^SMOKE_TENANT=//p' <<<"$vars"); form=$(sed -n 's/^SMOKE_FORM=//p' <<<"$vars")
  marker="SMOKE-$(openssl rand -hex 12)"
  sleep 1   # SDK key grace: the new signing key is current immediately; the pause only avoids a clock edge
  local rc=0
  sdk_submit() {  # args: extra submit.php arguments; prints the submission id
    php "$REPO_ROOT/sdk/php/bin/submit.php" --credentials "$SMOKE_WORK/sdk.json" --url "http://localhost:$public_port" "$@" 2>"$SMOKE_WORK/submit.err"
  }
  rid=$(sdk_submit "nachricht=$marker") || rc=$?
  check "Einsendung ueber oeffentliche Ingest-Route (SDK, signiert)" "$rc" 0
  (( rc == 0 )) || { head -3 "$SMOKE_WORK/submit.err" | cut -c1-200; return 1; }
  local q='mariadb -uroot -N form -e'
  dbq() { docker exec -e MYSQL_PWD="$pw" "$SMOKE_RUN-db" $q "$1"; }
  check "DB: submissions (accepted, 1 Zeile)" "$(dbq "SELECT COUNT(*) FROM submissions WHERE state='accepted'")" 1
  check "DB: Einsendungs-ID = Rueckgabe des SDK" "$(dbq "SELECT COUNT(*) FROM submissions WHERE LOWER(HEX(id))=REPLACE('$rid','-','')")" 1
  check "DB: stored_objects Rolle data vorhanden" "$(dbq "SELECT COUNT(*)>0 FROM stored_objects WHERE object_role='data' AND LENGTH(ciphertext)>0")" 1
  check "DB: stored_objects Chiffretext-Format" "$(dbq "SELECT COUNT(*)>0 FROM stored_objects WHERE object_role='data' AND packet_format='KUBUS-AEAD:2'")" 1
  check "Zero-Knowledge: Klartext nicht in stored_objects" "$(dbq "SELECT COUNT(*) FROM stored_objects WHERE LOCATE('$marker', ciphertext) > 0")" 0
  local dump_hits
  dump_hits=$(docker exec -e MYSQL_PWD="$pw" "$SMOKE_RUN-db" mariadb-dump -uroot --skip-extended-insert form 2>/dev/null | grep -a -c "$marker" || true)
  check "Zero-Knowledge: Klartext nicht im gesamten DB-Dump" "$dump_hits" 0
  local k1 k2
  k1=$(sdk_submit --key "smoke-$marker" "nachricht=$marker" || true); k2=$(sdk_submit --key "smoke-$marker" "nachricht=$marker" || true)
  check "Idempotenz: gleicher Schluessel, gleiche ID" "$([[ -n "$k1" && "$k1" == "$k2" ]] && echo gleich || echo "$k1/$k2")" gleich
  check "DB: Wiederholung erzeugt keine zweite Zeile (2 insgesamt)" "$(dbq "SELECT COUNT(*) FROM submissions WHERE state='accepted'")" 2
  check "Zero-Knowledge nach Wiederholung: Klartext nicht im Dump" "$(docker exec -e MYSQL_PWD="$pw" "$SMOKE_RUN-db" mariadb-dump -uroot --skip-extended-insert form 2>/dev/null | grep -a -c "$marker" || true)" 0
  check "keine Geheimnisse im App-Log" "$(docker logs "$SMOKE_RUN-app" 2>&1 | grep -c -e "$pw" -e "$key" || true)" 0
  return "$SMOKE_FAIL"
}

# ---------------------------------------------------------------- main

main() {
  local do_smoke=1 keep=0 smoke_only=""
  while (( $# )); do
    case $1 in
      --no-smoke) do_smoke=0 ;;
      --keep) keep=1 ;;
      --smoke-image) shift; smoke_only=${1:?--smoke-image braucht ein Image} ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  SMOKE_KEEP=$keep
  command -v docker >/dev/null && docker info >/dev/null 2>&1 || env_fail 'Docker-Daemon nicht erreichbar'
  if [[ -n "$smoke_only" ]]; then smoke_test "$smoke_only" && log "SMOKE ok" || { log "SMOKE FEHLGESCHLAGEN"; exit 1; }; exit 0; fi

  cd "$REPO_ROOT"
  local hash tag started elapsed
  hash=$(git rev-parse --short=12 HEAD)
  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] || hash="$hash-dirty"
  tag="$IMAGE_REPO:$hash"
  started=$(date +%s)
  build_pwa
  log "Image: baue $tag"
  docker build -f backend/Dockerfile --label "$BUILD_LABEL" --label "org.opencontainers.image.revision=$hash" -t "$tag" -t "$IMAGE_REPO:latest" .
  elapsed=$(( $(date +%s) - started ))
  log "Build-Dauer (inkl. PWA): ${elapsed}s"

  local rc=0
  if (( do_smoke )); then
    ( smoke_test "$tag" ) && log "SMOKE ok" || { rc=$?; log "SMOKE FEHLGESCHLAGEN"; }
  else
    log "Smoke-Test uebersprungen (--no-smoke)"
  fi
  if (( rc == 0 )); then
    prune_old_images "$IMAGE_REPO" "$KEEP_RECENT"
    docker image prune -f --filter "label=$BUILD_LABEL" >/dev/null 2>&1 || true
  fi
  log "Image-ID:  $(docker image inspect --format '{{.Id}}' "$tag")"
  log "Groesse:   $(docker image ls --format '{{.Size}}' "$tag") (docker image ls)"
  log "Tags:      $tag, $IMAGE_REPO:latest"
  log "IMAGE_TAG=$tag"
  exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
