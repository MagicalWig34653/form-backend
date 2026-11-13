#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Prüft die Sicherheitsheader eines Hosts hinter dem Proxy (HEAD-Anfrage).
# Usage: check-headers.sh URL [weitere curl-Argumente, z.B. -k --resolve host:443:127.0.0.1]
# Exit 0 = alle Header korrekt, 1 = Fehler, 2 = Umgebung (curl/URL).
set -u
[ $# -ge 1 ] || { echo "usage: $0 URL [curl args]"; exit 2; }
url=$1; shift
command -v curl >/dev/null || { echo "ENV: curl fehlt"; exit 2; }
hdrs=$(curl -sI --max-time 15 "$@" "$url" | tr -d '\r') || { echo "ENV: curl fehlgeschlagen"; exit 2; }
[ -n "$hdrs" ] || { echo "ENV: keine Antwort von $url"; exit 2; }
fail=0
val() { printf '%s\n' "$hdrs" | grep -i "^$1:"; }
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
for h in Strict-Transport-Security X-Content-Type-Options Referrer-Policy Permissions-Policy Content-Security-Policy; do
  n=$(val "$h" | wc -l | tr -d ' ')
  [ "$n" = 1 ] && ok "$h genau einmal" || bad "$h kommt ${n}-mal vor (erwartet 1)"
done
hsts=$(val Strict-Transport-Security | tr 'A-Z' 'a-z')
age=$(printf '%s' "$hsts" | sed -n 's/.*max-age=\([0-9]*\).*/\1/p')
[ "${age:-0}" -ge 31536000 ] && ok "HSTS max-age >= 1 Jahr" || bad "HSTS max-age < 31536000 (${age:-fehlt})"
case $hsts in *includesubdomains*) ok "HSTS includeSubDomains";; *) bad "HSTS ohne includeSubDomains";; esac
case $hsts in *preload*) bad "HSTS enthaelt preload (nicht erlaubt)";; *) ok "HSTS ohne preload";; esac
val X-Content-Type-Options | grep -qi 'nosniff' && ok "nosniff" || bad "X-Content-Type-Options != nosniff"
val Referrer-Policy | grep -qi 'no-referrer' && ok "Referrer-Policy no-referrer" || bad "Referrer-Policy != no-referrer"
val Permissions-Policy | grep -qi 'camera=()' && ok "Permissions-Policy camera=()" || bad "Permissions-Policy ohne camera=()"
val Content-Security-Policy | grep -qi "frame-ancestors 'none'" && ok "CSP frame-ancestors 'none'" || bad "CSP ohne frame-ancestors 'none'"
if [ $fail = 0 ]; then echo "RESULT: ok"; else echo "RESULT: FEHLER"; fi
exit $fail
