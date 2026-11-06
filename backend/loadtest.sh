#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Load probe: throwaway MariaDB + real binary, one form provisioned through the real UI (Playwright, synthetic data),
# then parallel PHP SDK submissions to the public listener. Measures success rate, p50/p95 latency, 429/5xx, stored
# submissions vs. unique idempotency keys, and /ready afterwards. Exit 0 ok, 1 failed, 2 environment.
# Tunables: LOAD_WORKERS (8), LOAD_TOTAL (400), LOAD_REPEATS (50), LOAD_RACE (8 parallel sends of one key).
set -u
cd "$(cd "$(dirname "$0")/.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; command -v "$DOCKER" >/dev/null 2>&1 || DOCKER=/opt/homebrew/bin/docker
NAME=p4a-loadtest-mariadb; PORT=${P3B_PORT:-33660}; WPORT=${E2E_PORT:-4260}; PPORT=$((WPORT+100))
W=${LOAD_WORKERS:-8}; N=${LOAD_TOTAL:-400}; R=${LOAD_REPEATS:-50}; RACE=${LOAD_RACE:-8}
PW=$(openssl rand -hex 16); TMP=$(mktemp -d); APP_PID=""
cleanup() { [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null; "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; rm -rf "$TMP"; echo "cleanup done"; }
trap cleanup EXIT
umask 077; openssl rand -hex 32 > "$TMP/server.key"
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --tmpfs /var/lib/mysql --name "$NAME" -p "127.0.0.1:$PORT:3306" -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=e2e "${MARIADB_IMAGE:-mariadb:lts}" >/dev/null || { echo "ENV: container"; exit 2; }
for _ in $(seq 90); do
  "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && sleep 2 && "$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -e 'select 1' e2e >/dev/null 2>&1 && up=1 && break; sleep 1
done
[ "${up:-0}" = 1 ] || { echo "ENV: db not ready"; exit 2; }
SB="swift build --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --product App"
export CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache"
$SB >/dev/null 2>&1 || { sleep 2; $SB >/dev/null 2>&1; } || { echo "ENV: build"; exit 2; }  # retry: the Swift frontend crashes sporadically
(cd pwa && npm run build >/dev/null 2>&1) || { echo "ENV: pwa build"; exit 2; }
BIN=backend/.build/debug/App
export FORM_DB_PORT=$PORT FORM_DB_USER=root FORM_DB_PASSWORD=$PW FORM_DB_NAME=e2e FORM_DB_TLS=disable FORM_ALLOW_INSECURE_DEV=1
export FORM_HTTP_PORT=$WPORT FORM_PUBLIC_PORT=$PPORT E2E_PUBLIC_URL=http://127.0.0.1:$PPORT FORM_SCHEMA_FILE=backend/db/schema-p3.sql FORM_PUBLIC_DIR="$PWD/pwa/dist"
export FORM_SERVER_KEY_FILE="$TMP/server.key" FORM_ADMIN_ORIGIN=http://localhost:$WPORT FORM_RP_ID=localhost
"$BIN" migrate >/dev/null 2>&1 || { echo "FAIL migrate"; exit 1; }
PASSWORD=$(openssl rand -hex 12); printf '%s' "$PASSWORD" > "$TMP/bootpw"
OUT=$(FORM_BOOTSTRAP_PASSWORD_FILE="$TMP/bootpw" "$BIN" bootstrap-admin admin 2>&1) || { echo "FAIL bootstrap-admin"; exit 1; }
LINK=$(printf '%s\n' "$OUT" | sed -n 's/.*): \(http[^ ]*\)$/\1/p' | head -1)
[ -n "$LINK" ] || { echo "FAIL no link"; exit 1; }
"$BIN" serve >"$TMP/app.log" 2>&1 & APP_PID=$!
for _ in $(seq 30); do curl -fs "http://localhost:$WPORT/health" >/dev/null 2>&1 && break; sleep 1; done
CRED="$TMP/credentials.json"
export E2E_SETUP_LINK="$LINK" E2E_PASSWORD="$PASSWORD" E2E_PORT=$WPORT E2E_SPEC=real-load-setup.spec.ts E2E_CREDENTIALS_OUT="$CRED"
(cd pwa && npx playwright test -c e2e-real/playwright.config.ts 2>&1 | tail -8)
[ -s "$CRED" ] || { echo "FAIL provisioning (no credentials)"; exit 1; }
echo "ok   form provisioned, credentials issued (not shown)"

URL=http://127.0.0.1:$PPORT; DRV=backend/loadtest/driver.php
# Phase 1: N unique keys over W workers, concurrently.
START=$(python3 -c 'import time;print(time.time())')
per=$((N / W)); pids=""
for w in $(seq 0 $((W-1))); do php "$DRV" "$CRED" "$URL" unique k $((w*per)) $(((w+1)*per)) >"$TMP/u$w.tsv" 2>"$TMP/u$w.err" & pids="$pids $!"; done
wait $pids
END=$(python3 -c 'import time;print(time.time())')
# Phase 2: R replays of already used keys (k-0 .. k-(R-1)), spread over the workers.
pids=""; rp=$(((R + W - 1) / W))
for w in $(seq 0 $((W-1))); do
  a=$((w*rp)); b=$(((w+1)*rp)); [ $b -gt $R ] && b=$R; [ $a -ge $b ] && continue
  php "$DRV" "$CRED" "$URL" replay k $a $b >"$TMP/r$w.tsv" 2>"$TMP/r$w.err" & pids="$pids $!"
done
wait $pids
# Phase 3: one new key sent by RACE processes at the same time (all must get the same id, one stored row).
pids=""
for w in $(seq 1 $RACE); do php "$DRV" "$CRED" "$URL" race "race-key=" 0 1 >"$TMP/c$w.tsv" 2>"$TMP/c$w.err" & pids="$pids $!"; done
wait $pids
cat "$TMP"/u*.tsv "$TMP"/r*.tsv "$TMP"/c*.tsv > "$TMP/all.tsv" 2>/dev/null
cat "$TMP"/*.err 2>/dev/null | head -3

rc=0
python3 - "$TMP/all.tsv" "$START" "$END" "$N" <<'PY' || rc=1
import sys
rows=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
start,end,n=float(sys.argv[2]),float(sys.argv[3]),int(sys.argv[4])
def pct(v,p):
    v=sorted(v)
    return v[min(len(v)-1,max(0,-(-p*len(v)//100)-1))] if v else float("nan")
def show(name,rs):
    lat=[float(x[3]) for x in rs]; ok=[x for x in rs if x[2]=="200"]
    c429=sum(1 for x in rs if x[2]=="429"); c5=sum(1 for x in rs if x[2].startswith("5")); other=len(rs)-len(ok)-c429-c5
    print(f"{name:7} requests={len(rs)} ok={len(ok)} ({100*len(ok)/max(1,len(rs)):.1f}%) 429={c429} 5xx={c5} other={other} p50={pct(lat,50):.0f}ms p95={pct(lat,95):.0f}ms max={max(lat or [0]):.0f}ms")
for ph in ("unique","replay","race"): show(ph,[x for x in rows if x[0]==ph])
show("all",rows)
print(f"unique phase throughput: {n/(end-start):.1f} req/s over {end-start:.1f}s")
ids={}
for x in rows:
    if x[2]=="200": ids.setdefault(x[1],set()).add(x[4])
bad=[k for k,v in ids.items() if len(v)!=1]
print(f"keys answered={len(ids)} keys with differing ids={len(bad)}")
sys.exit(1 if bad else 0)
PY
EXPECT=$((N + 1))  # N unique keys + the race key
STORED=$("$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N e2e -e 'SELECT COUNT(*) FROM submissions' 2>/dev/null)
DISTINCT=$("$DOCKER" exec -e MYSQL_PWD="$PW" "$NAME" mariadb -uroot -N e2e -e 'SELECT COUNT(DISTINCT id) FROM submissions' 2>/dev/null)
echo "stored submissions=$STORED distinct=$DISTINCT expected=$EXPECT"
[ "$STORED" = "$EXPECT" ] && [ "$DISTINCT" = "$EXPECT" ] && echo "ok   stored == unique keys, no duplicates" || { echo "FAIL stored count mismatch"; rc=1; }
READY=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$WPORT/ready"); PREADY=$(curl -s -o /dev/null -w '%{http_code}' "$URL/ready")
echo "/ready internal=$READY public=$PREADY"
[ "$READY" = 200 ] && echo "ok   /ready=200 after load" || { echo "FAIL /ready=$READY"; rc=1; }
kill -0 "$APP_PID" 2>/dev/null && echo "ok   app still running" || { echo "FAIL app died"; rc=1; }
exit $rc
