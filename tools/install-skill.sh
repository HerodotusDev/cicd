#!/usr/bin/env bash
# Install the cicd-onboard skill so an AI coding agent (Claude Code, Cursor,
# etc.) can load it. The skill lives in this repo at
# .cursor/skills/cicd-onboard; agents discover skills from per-user or
# per-repo skills dirs, so we link/copy it into one of those.
#
# Usage:
#   tools/install-skill.sh                 # global symlink into ~/.claude + ~/.agents (default)
#   tools/install-skill.sh --copy          # global copy instead of symlink (portable, goes stale)
#   tools/install-skill.sh --repo PATH     # install into an app repo's .claude/.agents/.cursor
#   tools/install-skill.sh --repo PATH --copy
#
# Symlink (default) tracks this checkout, so `git pull` in the cicd repo
# updates the skill everywhere. Use --copy only when the cicd repo won't be
# present (e.g. committing the skill into an app repo for teammates).
set -euo pipefail

SKILL="cicd-onboard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/../.cursor/skills/$SKILL" && pwd)"

MODE="symlink"   # symlink | copy
TARGET_REPO=""   # empty => global (~)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy) MODE="copy"; shift ;;
    --repo) TARGET_REPO="${2:?--repo needs a path}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Install the cicd-onboard skill into an AI agent's skills dir.

  tools/install-skill.sh                 # global symlink into ~/.claude + ~/.agents (default)
  tools/install-skill.sh --copy          # global copy instead of symlink (portable, goes stale)
  tools/install-skill.sh --repo PATH     # install into an app repo's .claude/.agents/.cursor
  tools/install-skill.sh --repo PATH --copy

Symlink (default) tracks this checkout, so a `git pull` of the cicd repo
updates the skill everywhere. Use --copy when the cicd repo won't be present.
EOF
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$SRC" ]]; then
  echo "❌ Skill source not found at $SRC" >&2
  exit 1
fi

# Resolve destination skills dirs.
if [[ -n "$TARGET_REPO" ]]; then
  base="$(cd "$TARGET_REPO" && pwd)"
  dests=("$base/.claude/skills" "$base/.agents/skills" "$base/.cursor/skills")
  scope="repo ($base)"
else
  dests=("$HOME/.claude/skills" "$HOME/.agents/skills")
  scope="global (~)"
fi

echo "Installing '$SKILL' [$MODE] → $scope"
for dir in "${dests[@]}"; do
  mkdir -p "$dir"
  dest="$dir/$SKILL"
  if [[ "$MODE" == "symlink" ]]; then
    ln -sfn "$SRC" "$dest"
    echo "  linked  $dest -> $SRC"
  else
    rm -rf "$dest"
    cp -R "$SRC" "$dest"
    echo "  copied  $dest"
  fi
done

echo "✅ Done. Reload your agent / reopen the repo to pick up the skill."
