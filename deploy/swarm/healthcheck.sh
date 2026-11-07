#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
# Docker bounds the check with HEALTH_TIMEOUT. Ports are direct ENV only.
port=${FORM_INTERNAL_PORT:-8081}
exec 3<>"/dev/tcp/127.0.0.1/$port"
printf 'GET /ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
IFS= read -r status <&3
exec 3>&-
[[ "$status" == *' 200 '* ]]
