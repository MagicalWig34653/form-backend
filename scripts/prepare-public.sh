#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Builds a sanitized, history-free export of the current HEAD for the public release. It never pushes and never touches the
# working repository. Result: a new directory with ONE initial commit, scanned with gitleaks and a project denylist.
#
#   scripts/prepare-public.sh OUTPUT_DIR [--drop-paritaet] [--drop-handoffs] [--drop-agents] [--keep-todolino]
#
# Exit 0 = export is clean, 1 = a check failed (output kept for inspection), 2 = environment problem.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd -P)"
OUT=${1:?Usage: scripts/prepare-public.sh OUTPUT_DIR [--drop-paritaet] [--drop-handoffs] [--drop-agents] [--keep-todolino]}
shift
DROP_PARITAET=0; DROP_HANDOFFS=0; DROP_AGENTS=0; KEEP_TODOLINO=0
for a in "$@"; do
  case "$a" in
    --drop-paritaet) DROP_PARITAET=1 ;; --drop-handoffs) DROP_HANDOFFS=1 ;; --drop-agents) DROP_AGENTS=1 ;; --keep-todolino) KEEP_TODOLINO=1 ;;
    *) echo "Unbekannte Option: $a" >&2; exit 2 ;;
  esac
done
[ ! -e "$OUT" ] || { echo "Zielverzeichnis existiert bereits: $OUT" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "Arbeitsverzeichnis ist nicht sauber (nur committete Stände werden exportiert)" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker fehlt (für gitleaks)" >&2; exit 2; }
SRC_COMMIT=$(git rev-parse --short HEAD)

mkdir -p "$OUT"
git archive HEAD | tar -x -C "$OUT"
cd "$OUT"

# 1. Remove internal tooling that is meaningless or sensitive outside the team.
[ "$KEEP_TODOLINO" = 1 ] || rm -f .todolino.json
[ "$DROP_AGENTS" = 0 ] || rm -rf .claude
[ "$DROP_PARITAET" = 0 ] || rm -rf docs/paritaet
[ "$DROP_HANDOFFS" = 0 ] || rm -rf docs/handoffs
rm -rf docs/ux/bilder-ist  # screenshots of the mock UI are working material, not documentation

# 2. Rewrite local absolute paths and machine-specific names in text files.
FILES=$(grep -rIl --exclude-dir=.git -E '/Users/[A-Za-z0-9._-]+/' . || true)
if [ -n "$FILES" ]; then
  # shellcheck disable=SC2086
  perl -pi -e 's{/Users/[A-Za-z0-9._-]+/Documents/Code Projekte/PhpstormProjects/}{<workspace>/}g; s{/Users/[A-Za-z0-9._-]+/Development/PhpstormProjects/}{<workspace>/}g; s{/Users/[A-Za-z0-9._-]+/Library/}{~/Library/}g; s{/Users/[A-Za-z0-9._-]+/}{~/}g' $FILES
fi

# 2b. Replace known customer/production identifiers by neutral placeholders (docs only mention them as examples of the legacy system).
FILES=$(grep -rIl --exclude-dir=.git -E '92bd1241-3d24|de73285d-31a9|f6091a4b-2afe|2f3f55ae-54a4|[Bb]a?esserl(ä|ae)chler|legacy-dump' . || true)
if [ -n "$FILES" ]; then
  # shellcheck disable=SC2086
  perl -pi -e 's/00000000-0000-4000-8000-0000000000b2/00000000-0000-4000-8000-0000000000b2/g; s/00000000-0000-4000-8000-0000000000b3/00000000-0000-4000-8000-0000000000b3/g; s/00000000-0000-4000-8000-0000000000b1/00000000-0000-4000-8000-0000000000b1/g; s/00000000-0000-4000-8000-0000000000c1/00000000-0000-4000-8000-0000000000c1/g; s/[Bb]aesserlaechler/KundeB/g; s/[Bb]esserl(?:ä|ae)chler/KundeB/g; s/legacy-dump/legacy-dump/g' $FILES
fi

# 2c. Internal analysis/handoff directories may be dropped: tell readers why references to them dangle.
if [ "$DROP_PARITAET" = 1 ] || [ "$DROP_HANDOFFS" = 1 ]; then
  cat >> docs/STATUS.md <<'NOTE'

> **Hinweis zum öffentlichen Export:** Verweise auf `docs/paritaet/` (Analyse des Altsystems), `docs/handoffs/` (interne Übergaben) und `.claude/agents/` zeigen auf Material, das in dieser Veröffentlichung bewusst fehlt. Maßgeblich sind README, `docs/BETRIEB.md`, `docs/decisions/` (ADR) und `contracts/`.
NOTE
fi

# 3. Project denylist (customer identifiers, personal data). Extend scripts/public-denylist.txt, one extended regex per line.
DENY="$OLDPWD/scripts/public-denylist.txt"
rm -f scripts/public-denylist.txt   # the list itself names the identifiers; it is not part of the public tree
FAIL=0
if [ -f "$DENY" ]; then
  while IFS= read -r pattern; do
    case "$pattern" in ''|'#'*) continue ;; esac
    hits=$(grep -rIniE --exclude-dir=.git -e "$pattern" . 2>/dev/null | head -5 || true)
    if [ -n "$hits" ]; then echo "DENYLIST-Treffer für /$pattern/:"; echo "$hits" | cut -c1-200; FAIL=1; fi
  done < "$DENY"
fi

# 4. Secret scan on the export (no history yet), then the single initial commit.
git init -q -b main
git add -A
GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-"form-backend maintainers"} GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-"noreply@users.noreply.github.com"} \
GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME:-"form-backend maintainers"} GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL:-"noreply@users.noreply.github.com"} \
  git commit -q -m "Initial public release (export of internal history at $SRC_COMMIT)"
if ! docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:v8.30.1 detect --source /repo --config /repo/.gitleaks.toml --no-banner --redact >/tmp/prepare-public-gitleaks.log 2>&1; then
  echo "gitleaks meldet Funde:"; tail -5 /tmp/prepare-public-gitleaks.log; FAIL=1
fi

echo "Export: $OUT (aus $SRC_COMMIT), Dateien: $(git ls-files | wc -l | tr -d ' ')"
if [ "$FAIL" = 1 ]; then echo "FEHLER: Prüfungen fehlgeschlagen; Export nicht veröffentlichen."; exit 1; fi
echo "OK: keine Denylist-/Secret-Treffer. Nächste Schritte: docs/VEROEFFENTLICHUNG.md (Abschnitt 'Veröffentlichen')."
