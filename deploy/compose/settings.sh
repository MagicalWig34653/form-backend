#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Einstellungen der Compose-.env per Menü oder CLI (--list, --get, --set, --unset, --check); Logik in deploy/swarm/settings.sh.
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_MODE=compose exec "${BASH:-bash}" "$BASE/../swarm/settings.sh" "$@"
