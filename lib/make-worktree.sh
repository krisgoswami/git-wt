#!/usr/bin/env bash
# Create a worktree and initialise it. The path comes from the layout rules in
# lib/common.sh — by default <repo>/.worktrees/<branch>, or
# <repo>/.claude/worktrees/<branch> when the repo has a .claude/ directory,
# because that exact path is what Claude Code treats as pre-approved.
set -euo pipefail

# Locate this script's own directory with symlinks resolved, without GNU
# readlink — the clone itself may sit behind a symlink.
_wt_self=$0
while [ -L "$_wt_self" ]; do
  _wt_link=$(readlink "$_wt_self")
  case "$_wt_link" in
    /*) _wt_self=$_wt_link ;;
    *)  _wt_self=$(dirname "$_wt_self")/$_wt_link ;;
  esac
done
WT_LIB_DIR=$(cd "$(dirname "$_wt_self")" && pwd -P)
# shellcheck source=./common.sh
. "$WT_LIB_DIR/common.sh"

NO_INSTALL=false
BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) NO_INSTALL=true; shift ;;
    -h | --help)
      echo "Usage: wt new <branch> [--no-install]" >&2
      exit 0
      ;;
    --)
      shift
      BRANCH=${1:-}
      shift || true
      ;;
    -*)
      echo "git-wt: unknown option '$1'" >&2
      exit 1
      ;;
    *)
      [ -n "$BRANCH" ] && { echo "git-wt: unexpected argument '$1'" >&2; exit 1; }
      BRANCH=$1
      shift
      ;;
  esac
done

if [ -z "$BRANCH" ]; then
  echo "Usage: wt new <branch> [--no-install]" >&2
  exit 1
fi

wt_check_branch_name "$BRANCH"
wt_require_repo

git fetch origin > /dev/null 2>&1 || echo "Warning: fetch failed, using local refs" >&2

MAIN_REPO_PATH=$(wt_main_repo)
BASE_DIR=$(wt_base_dir "$MAIN_REPO_PATH")
LAYOUT=$(wt_layout "$MAIN_REPO_PATH")
WORKTREE_PATH="$BASE_DIR/$BRANCH"

if [ -e "$WORKTREE_PATH" ]; then
  echo "Error: $WORKTREE_PATH already exists" >&2
  exit 1
fi

# A previously failed create leaves a stale admin dir under .git/worktrees/
# that blocks reusing the name; pruning first makes a retry work.
git worktree prune || true

BRANCH_PREEXISTED=false
git rev-parse --verify --quiet "refs/heads/$BRANCH" > /dev/null && BRANCH_PREEXISTED=true

BASE=$(wt_default_ref || true)
if [ -z "$BASE" ]; then
  BASE=HEAD
  wt_warn_no_default_ref
  echo "         Branching off your current HEAD ($(git rev-parse --abbrev-ref HEAD))." >&2
fi

echo "Creating worktree for '$BRANCH' at $WORKTREE_PATH (base: $BASE, layout: $LAYOUT)..."
mkdir -p "$(dirname "$WORKTREE_PATH")"

ADD_OK=true
if [ "$BRANCH_PREEXISTED" = true ]; then
  git worktree add "$WORKTREE_PATH" "$BRANCH" || ADD_OK=false
else
  # --no-track is load bearing. Branching from a remote-tracking ref otherwise
  # makes git set that ref as the new branch's upstream, and a plain `git push`
  # would then deliver your commits straight onto the shared default branch.
  git worktree add "$WORKTREE_PATH" --no-track -b "$BRANCH" "$BASE" || ADD_OK=false
fi

if [ "$ADD_OK" = false ]; then
  echo "Error: failed to create worktree for '$BRANCH'" >&2
  git worktree prune || true
  # Roll back the branch only if this run created it — never a pre-existing one.
  if [ "$BRANCH_PREEXISTED" = false ] && ! git worktree list | grep -qF "[$BRANCH]"; then
    git branch -D "$BRANCH" 2> /dev/null || true
  fi
  exit 1
fi

INIT_ARGS=()
[ "$NO_INSTALL" = true ] && INIT_ARGS+=(--no-install)
cd "$WORKTREE_PATH"
"$WT_LIB_DIR/init-worktree.sh" ${INIT_ARGS[@]+"${INIT_ARGS[@]}"}

echo ""
echo "✓ Worktree created"
echo "  Branch: $BRANCH"
echo "  Path:   $WORKTREE_PATH"
echo ""
echo "Jump into it with: wt $BRANCH"
