#!/usr/bin/env bash
# Save progress: stage everything, commit, push current branch to origin.
# Purpose: kill the "weeks of uncommitted work" gap. Commit ≠ build — run this
# after every logical change, regardless of when we build the .app.
#
# Usage:
#   ./scripts/save.sh                 # auto message "wip: save progress <date>"
#   ./scripts/save.sh "feat(ui): ..." # explicit message
set -euo pipefail
cd "$(dirname "$0")/.."

branch="$(git rev-parse --abbrev-ref HEAD)"

git add -A
if git diff --cached --quiet; then
    echo "Nothing to commit — working tree clean."
    # Still make sure nothing is sitting unpushed.
    if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        ahead="$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)"
        if [ "$ahead" -gt 0 ]; then
            echo "Pushing $ahead unpushed commit(s) on '$branch'…"
            git push
        fi
    else
        echo "⚠️  '$branch' has no upstream — run: git push -u origin $branch"
    fi
    exit 0
fi

msg="${1:-wip: save progress $(date '+%Y-%m-%d %H:%M')}"
git commit -m "$msg"
git push -u origin "$branch"
echo "✅ committed + pushed → origin/$branch"
