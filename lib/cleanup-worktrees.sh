#!/usr/bin/env bash
# Remove worktrees whose work has landed, and the branches left behind.
# "Landed" is either of two signals, because neither alone is enough: the
# remote dropped the branch ([gone]), or the branch tip is an ancestor of the
# default branch. A team that does not delete branches on merge only ever
# produces the second, and a branch that never tracked a remote can never
# produce the first. Preview with --whatif first.
set -euo pipefail

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

WHATIF=false
FORCE=false
DAYS=${WT_GONE_DAYS:-7}
while [ $# -gt 0 ]; do
  case "$1" in
    --whatif | --dry-run) WHATIF=true; shift ;;
    --force) FORCE=true; shift ;;
    --days)
      DAYS=${2:-7}
      shift 2
      ;;
    -h | --help)
      echo "Usage: wt clean [--whatif] [--force] [--days N]" >&2
      exit 0
      ;;
    *)
      echo "Usage: wt clean [--whatif] [--force] [--days N]" >&2
      exit 1
      ;;
  esac
done

case "$DAYS" in
  '' | *[!0-9]*)
    echo "git-wt: --days wants a whole number, got '$DAYS'" >&2
    exit 1
    ;;
esac

wt_require_repo

# Resolve where the caller is standing BEFORE cd-ing to the main checkout;
# afterwards show-toplevel would just report the main checkout, and the
# "you are standing in it" guard would silently never fire.
CURRENT_WT=$(git rev-parse --show-toplevel 2> /dev/null || echo "")
MAIN_REPO_PATH=$(wt_main_repo)
cd "$MAIN_REPO_PATH"

run() { if [ "$WHATIF" = true ]; then echo "  would: $*"; else "$@"; fi; }

echo "Pruning stale worktree admin dirs..."
run git worktree prune

# The only remote interaction in the whole tool, and it is read-only on the
# remote: --prune deletes stale local origin/* tracking refs, nothing else.
git fetch --prune origin > /dev/null 2>&1 || echo "Warning: fetch failed" >&2

DEFAULT_REF=$(wt_default_ref || true)
if [ -z "$DEFAULT_REF" ]; then
  wt_warn_no_default_ref
  echo "         Cannot tell what has landed without it. Nothing was changed." >&2
  exit 1
fi
DEFAULT_BRANCH=${DEFAULT_REF#origin/}

CUTOFF=$(( $(date +%s) - DAYS * 86400 ))

echo ""
echo "Worktrees whose work has landed:"
SKIPPED_DIRTY=0
FOUND=0
# Feed the list in from a process substitution, not a pipe: a pipe would run
# the loop in a subshell and the counters set inside it would not survive.
while read -r wt_path wt_branch; do
  [ -z "$wt_branch" ] && continue                        # detached, leave alone
  [ "$wt_branch" = "$DEFAULT_BRANCH" ] && continue
  [ "$wt_path" = "$MAIN_REPO_PATH" ] && continue
  if [ "$wt_path" = "$CURRENT_WT" ]; then
    echo "  skipping $wt_branch (you are standing in it)"
    continue
  fi

  reason=""
  upstream_state=$(git for-each-ref --format='%(upstream:track)' "refs/heads/$wt_branch")
  if [ "$upstream_state" = "[gone]" ]; then
    # A closed or rejected pull request also goes [gone] while still holding
    # unmerged commits, so hold this signal to the --days window.
    last_commit=$(git log -1 --format=%ct "$wt_branch" 2> /dev/null || echo 0)
    if [ "$last_commit" -lt "$CUTOFF" ]; then
      echo "  keeping $wt_branch (upstream gone, but older than $DAYS days — check it by hand)"
      continue
    fi
    reason="upstream gone"
  elif git merge-base --is-ancestor "$wt_branch" "$DEFAULT_REF" 2> /dev/null; then
    # Ancestry is proof the commits are in the default branch, so no age window
    # applies here. Note a SQUASH merge rewrites the commits and will not
    # satisfy this — such a branch is kept and must be judged by hand.
    reason="merged into $DEFAULT_BRANCH"
  else
    continue
  fi
  FOUND=$((FOUND + 1))

  # Never destroy uncommitted work. `git worktree remove` refuses on its own,
  # but check first so the run reports it instead of dying under `set -e`.
  # Untracked files count as dirty: a stray .env or build output trips this,
  # and that is the correct behaviour.
  if [ -n "$(git -C "$wt_path" status --porcelain 2> /dev/null)" ]; then
    if [ "$FORCE" != true ]; then
      echo "  KEEPING $wt_branch ($reason) — has uncommitted changes"
      SKIPPED_DIRTY=$((SKIPPED_DIRTY + 1))
      continue
    fi
    echo "  $wt_branch ($reason) — DISCARDING uncommitted changes (--force)"
    run git worktree remove --force "$wt_path"
  else
    echo "  $wt_branch ($reason)"
    run git worktree remove "$wt_path"
  fi

  # Removing a worktree does not delete its branch, and a branch cannot be
  # deleted while a worktree holds it — so they have to be cleaned together.
  # -d, not -D: it refuses if the branch still holds unmerged commits, which is
  # exactly the case the [gone] signal cannot distinguish.
  run git branch -d "$wt_branch" || echo "    (branch kept: not fully merged)"
done < <(git worktree list --porcelain | awk '
  /^worktree /{p=substr($0,10)}
  /^branch /{sub("refs/heads/","",$2); print p, $2}')

[ "$FOUND" -eq 0 ] && echo "  (none)"

if [ "$SKIPPED_DIRTY" -gt 0 ]; then
  echo ""
  echo "  $SKIPPED_DIRTY worktree(s) kept because of uncommitted changes."
  echo "  Review them, then re-run with --force to discard that work."
fi

echo ""
echo "Branches with no worktree, merged into $DEFAULT_BRANCH:"
FOUND_BRANCH=0
CHECKED_OUT=$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}')
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  case "$b" in main | master | develop | "$DEFAULT_BRANCH") continue ;; esac
  echo "$CHECKED_OUT" | grep -qxF "$b" && continue
  if git merge-base --is-ancestor "$b" "$DEFAULT_REF" 2> /dev/null; then
    echo "  $b"
    FOUND_BRANCH=$((FOUND_BRANCH + 1))
    # -D is safe here and only here: ancestry already proved the commits are in
    # the default branch. -d alone would refuse whenever the local default
    # branch is behind its remote.
    run git branch -D "$b"
  fi
done
[ "$FOUND_BRANCH" -eq 0 ] && echo "  (none)"

[ "$WHATIF" = true ] && echo "" && echo "(--whatif: nothing was changed)"
echo "✓ done"
