#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
# P11-A: lib.sh validates/renders both listeners and optional port publications.
MODE=compose
ACTION=setup
# shellcheck source=deploy/swarm/lib.sh
source "$BASE/../swarm/lib.sh"
main "$@"
