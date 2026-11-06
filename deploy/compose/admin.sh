#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Operator one-off: bootstrap-admin (first administrator + one-time passkey enrollment link) or enroll-passkey.
#   deploy/compose/admin.sh bootstrap-admin [BENUTZER]      # BENUTZER default: admin
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
MODE=compose
ACTION=admin
# shellcheck source=deploy/swarm/lib.sh
source "$BASE/../swarm/lib.sh"
main "$@"
