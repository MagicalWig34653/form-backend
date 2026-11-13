#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Exports this checkout (without private material), mirrors it into the public repository checkout and commits there.
# Every step must succeed (set -e); a plausibility check refuses to commit when the export would delete a large part of the
# public tree (this happened on 13.11.2026 when a failed export directory was mirrored: 1063 files deleted).
#   scripts/publish-public.sh [--push] [--public-dir ../form-backend-public] [--message "text"]
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd -P)"
PUBLIC=../form-backend-public; PUSH=0; MSG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --public-dir) PUBLIC=${2:?}; shift ;;
    --message) MSG=${2:?}; shift ;;
    -h|--help) sed -n 2,8p "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done
[ -d "$PUBLIC/.git" ] || { echo "public checkout missing: $PUBLIC" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean: commit first" >&2; exit 2; }
[ -z "$(git -C "$PUBLIC" status --porcelain)" ] || { echo "public checkout not clean" >&2; exit 2; }
SRC=$(git rev-parse --short HEAD)
mkdir -p "$HOME/.cache"
EXPORT=$(mktemp -d "$HOME/.cache/form-export.XXXXXX")  # fresh, empty; under $HOME because Docker (colima) only mounts $HOME for the gitleaks check
trap 'rm -rf "$EXPORT" 2>/dev/null || true' EXIT
rmdir "$EXPORT"  # prepare-public.sh requires a directory that does not exist yet
scripts/prepare-public.sh "$EXPORT" --drop-paritaet --drop-handoffs --drop-agents
rm -rf "$EXPORT/docs/ux/konzepte"
for p in .claude .todolino.json docs/handoffs docs/paritaet docs/ux/konzepte; do
  [ ! -e "$EXPORT/$p" ] || { echo "private path in export: $p" >&2; exit 3; }
done
files=$(find "$EXPORT" -type f -not -path "$EXPORT/.git/*" | wc -l | tr -d ' ')
before=$(git -C "$PUBLIC" ls-files | wc -l | tr -d ' ')
echo "export files: $files, public tree before: $before"
# plausibility: the export must be at least 90 % of the public tree (a normal change adds or removes a handful of files)
[ "$files" -ge $(( before * 9 / 10 )) ] || { echo "REFUSED: export has $files files, public has $before (would delete too much)" >&2; exit 4; }
docker run --rm -v "$EXPORT:/repo" zricethezav/gitleaks:v8.30.1 detect --no-git --source /repo --config /repo/.gitleaks.toml --no-banner --redact
rsync -a --delete --exclude='.git' --exclude='.DS_Store' "$EXPORT/" "$PUBLIC/"
# macOS Finder metadata is never published
[ -z "$(git -C "$PUBLIC" ls-files '*.DS_Store')" ] || git -C "$PUBLIC" rm -q --cached -- $(git -C "$PUBLIC" ls-files '*.DS_Store')
git -C "$PUBLIC" add -A
deleted=$(git -C "$PUBLIC" diff --cached --diff-filter=D --name-only | wc -l | tr -d ' ')
[ "$deleted" -le $(( before / 20 + 5 )) ] || { echo "REFUSED: $deleted files would be deleted" >&2; git -C "$PUBLIC" reset -q; exit 4; }
if git -C "$PUBLIC" diff --cached --quiet; then echo "nothing to publish"; exit 0; fi
git -C "$PUBLIC" diff --cached --stat | tail -1
git -C "$PUBLIC" -c user.name="$(git config user.name)" -c user.email="$(git config user.email || echo noreply@example.invalid)" \
  commit -q -m "${MSG:-Export aus $SRC}"
git -C "$PUBLIC" log --oneline -1
if [ "$PUSH" = 1 ]; then git -C "$PUBLIC" push origin main; else echo "committed locally; push with: git -C $PUBLIC push origin main"; fi
