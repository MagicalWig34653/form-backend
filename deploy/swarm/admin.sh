#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Operator one-off: bootstrap-admin (first administrator + one-time passkey enrollment link) or enroll-passkey.
#   deploy/swarm/admin.sh bootstrap-admin [BENUTZER]      # BENUTZER default: admin
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
MODE=swarm
ACTION=admin
# shellcheck source=deploy/swarm/lib.sh
source "$BASE/../swarm/lib.sh"
main "$@"
