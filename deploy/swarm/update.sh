#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
# P11-A: lib.sh validates/renders both listeners and optional port publications.
MODE=swarm
ACTION=update
# shellcheck source=deploy/swarm/lib.sh
source "$BASE/lib.sh"
# Placement prompts, dry-run and anchored stack rendering are shared in lib.sh.
main "$@"
