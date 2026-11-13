#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Prüft deploy/proxy/nginx.conf.example in einem lokalen nginx-Container: nginx -t, Header-Check
# (check-headers.sh) gegen beide Server-Blöcke mit Backend-Attrappe, IP-Kürzung (IPv4/IPv6) und Access-Log.
# Usage: bash deploy/proxy/test-template.sh      Exit 0 = ok, 1 = Prüfung fehlgeschlagen, 2 = Umgebung.
set -u
cd "$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 1
DOCKER=${DOCKER:-docker}; NGINX_IMAGE=${NGINX_IMAGE:-nginx:stable-alpine}; PORT=${PROXY_TEST_PORT:-38743}
NAME=formproxytest-$$; WORK=$(mktemp -d "${PROBE_TMP:-$HOME}/formproxytest.XXXXXX"); fail=0
cleanup() { "$DOCKER" rm -f "$NAME" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
"$DOCKER" info >/dev/null 2>&1 || { echo "ENV: docker daemon not reachable"; exit 2; }
command -v openssl >/dev/null || { echo "ENV: openssl fehlt"; exit 2; }
chk() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
mkdir -p "$WORK/tls/forms" "$WORK/tls/admin" "$WORK/logs"
for d in forms admin; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$d.example.org" \
    -keyout "$WORK/tls/$d/privkey.pem" -out "$WORK/tls/$d/fullchain.pem" >/dev/null 2>&1 || { echo "ENV: openssl req failed"; exit 2; }
done
# Vorlage anpassen: interne Listen-Adresse -> 443 (Namensbasiert), Log-Pfade -> beschreibbares Verzeichnis.
sed -e 's#listen 10.20.0.10:443#listen 443#' -e 's#/var/log/nginx/#/logs/#g' deploy/proxy/nginx.conf.example > "$WORK/template.conf"
# Testvariante der IP-Map (Quelle ist ein Request-Header), damit IPv6-Fälle prüfbar sind.
sed -e 's#^map \$remote_addr \$form_log_ip#map $http_x_test_ip $form_log_ip#' "$WORK/template.conf" > "$WORK/template-map.conf"
cat > "$WORK/nginx.conf" <<'EOF'
pid /tmp/nginx.pid;
events {}
http {
  include /etc/nginx/template.conf;
  # Backend-Attrappe wie die App: eigene nosniff/Referrer-Policy; HTML mit CSP, API ohne.
  server { listen 127.0.0.1:8080; listen 127.0.0.1:8081; client_max_body_size 100m;
    location = /index.html { default_type text/html; add_header X-Content-Type-Options nosniff; add_header Referrer-Policy no-referrer;
      add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none'"; return 200 "<html></html>"; }
    location / { default_type application/json; add_header X-Content-Type-Options nosniff; return 200 "{}"; } }
}
EOF
cat > "$WORK/nginx-map.conf" <<'EOF'
pid /tmp/nginx.pid;
events {}
http {
  include /etc/nginx/template-map.conf;
  server { listen 127.0.0.1:8080; listen 127.0.0.1:8081; location / { return 200 "{}"; } }
  server { listen 8099; location / { return 200 "$form_log_ip"; } }
}
EOF
common=(--add-host form-public:127.0.0.1 --add-host form-internal:127.0.0.1
  -v "$WORK/template.conf:/etc/nginx/template.conf:ro" -v "$WORK/template-map.conf:/etc/nginx/template-map.conf:ro"
  -v "$WORK/tls:/etc/nginx/tls:ro" -v "$WORK/logs:/logs")
"$DOCKER" run --rm "${common[@]}" -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" nginx -t 2>&1
chk $? "nginx -t (Vorlage)"
"$DOCKER" run -d --name "$NAME" -p "127.0.0.1:$PORT:443" -p "127.0.0.1:$((PORT+1)):8099" "${common[@]}" \
  -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$WORK/nginx-map.conf:/etc/nginx/nginx-map.conf:ro" "$NGINX_IMAGE" >/dev/null || exit 2
sleep 2
for host in forms.example.org admin.example.org; do
  for path in index.html api/x; do
    echo "--- https://$host/$path"
    bash deploy/proxy/check-headers.sh "https://$host:443/$path" -k --resolve "$host:443:127.0.0.1" --connect-to "$host:443:127.0.0.1:$PORT"
    chk $? "Header $host/$path"
  done
done
# IP-Kürzung: zweiter Lauf mit Test-Map (Quelle = Header X-Test-IP).
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --name "$NAME" -p "127.0.0.1:$((PORT+1)):8099" "${common[@]}" \
  -v "$WORK/nginx-map.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" >/dev/null || exit 2
sleep 2
anon() { curl -s --max-time 5 -H "X-Test-IP: $1" "http://127.0.0.1:$((PORT+1))/"; }
for pair in "203.0.113.77=203.0.113.0" "2001:db8:abcd:1234:5678::9=2001:db8:abcd::" "2001:db8::1=2001:db8::" "::1=::" "::ffff:192.0.2.5=::" "2a02:810:1:2:3:4:5:6=2a02:810:1::"; do
  in=${pair%%=*}; want=${pair#*=}; got=$(anon "$in")
  [ "$got" = "$want" ]; chk $? "Kürzung $in -> $got (erwartet $want)"
done
# Access-Log der echten Konfiguration: keine volle IPv4, kein Query-String.
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1
"$DOCKER" run -d --name "$NAME" -p "127.0.0.1:$PORT:443" "${common[@]}" -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" >/dev/null || exit 2
sleep 2
curl -sk --max-time 5 -o /dev/null --connect-to forms.example.org:443:127.0.0.1:$PORT "https://forms.example.org/api/x?token=SECRET123"
sleep 1
log=$(cat "$WORK/logs/form-access.log" 2>/dev/null); echo "access-log: $log"
printf '%s' "$log" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.0 '; chk $? "Access-Log: IPv4 auf .0 gekürzt (oder IPv6 gekürzt)"
printf '%s' "$log" | grep -q SECRET123; [ $? -ne 0 ]; chk $? "Access-Log ohne Query-String"
# Body-Grenzen (fb-sec 1/2): Eingang 32 MiB (Vorlage 33m), interner Host 64 MiB (65m); nginx-Standard 1 MiB wäre zu klein.
code() { curl -sk --max-time 30 -o /dev/null -w '%{http_code}' -X POST --data-binary "@$WORK/body-$1" --connect-to "$2:443:127.0.0.1:$PORT" "https://$2/api/x"; }
for mb in 2 34 40 66; do head -c $((mb * 1024 * 1024)) /dev/zero > "$WORK/body-$mb"; done
[ "$(code 2 forms.example.org)" = 200 ]; chk $? "Eingang: 2 MiB werden durchgelassen (Standard-nginx: 413)"
[ "$(code 34 forms.example.org)" = 413 ]; chk $? "Eingang: 34 MiB -> 413 am Proxy"
[ "$(code 40 admin.example.org)" = 200 ]; chk $? "Intern: 40 MiB werden durchgelassen"
[ "$(code 66 admin.example.org)" = 413 ]; chk $? "Intern: 66 MiB -> 413 am Proxy"
for h in X-Real-IP X-Forwarded-For; do [ "$(grep -c "proxy_set_header $h " deploy/proxy/nginx.conf.example)" -ge 2 ]; chk $? "Vorlage setzt $h"; done
grep -q 'limit_conn form_conn' deploy/proxy/nginx.conf.example; chk $? "Vorlage enthält limit_conn"
if [ $fail = 0 ]; then echo "RESULT: ok"; else echo "RESULT: FEHLER"; fi
exit $fail
