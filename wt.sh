# git-wt — source this from ~/.bashrc or ~/.zshrc. Do not put it on PATH.
# shellcheck shell=bash
#
# Jumping between worktrees has to change the CALLING shell's directory, and a
# child process cannot do that to its parent. That is the whole reason this is
# a sourced function and not a script.
#
# Works in bash and zsh.

# Find our own directory, following symlinks, in whichever shell sourced us.
# bash exposes BASH_SOURCE; zsh needs ${(%):-%x}, which bash cannot even parse,
# so it goes through eval.
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_wt_self=${(%):-%x}'
elif [ -n "${BASH_VERSION:-}" ]; then
  _wt_self=${BASH_SOURCE[0]}
else
  _wt_self=$0
fi
while [ -L "$_wt_self" ]; do
  _wt_link=$(readlink "$_wt_self")
  case "$_wt_link" in
    /*) _wt_self=$_wt_link ;;
    *)  _wt_self=$(dirname "$_wt_self")/$_wt_link ;;
  esac
done
WT_HOME=${WT_HOME:-$(cd "$(dirname "$_wt_self")" && pwd -P)}
unset _wt_self _wt_link
export WT_HOME

wt() {
  local cmd="${1:-list}"

  case "$cmd" in
    help | -h | --help)
      cat <<'HELP'
wt / wt ls / wt list            list every worktree
wt <substring>                  jump to the worktree whose branch or path matches
wt new <branch>                 create and initialise a worktree (alias: create)
wt new <branch> --no-install    ...without installing dependencies
wt clean                        remove worktrees whose work has landed
wt clean --whatif               preview it, change nothing (alias: --dry-run)
wt clean --force                also remove dirty ones, discarding changes
wt clean --days N               how recent a [gone] branch must be (default 7)
wt root                         jump back to the main checkout
wt path <substring>             print a worktree's path without jumping
wt update                       pull the latest git-wt and reload it
wt help                         this

An ambiguous jump goes to the first match and prints the rest.

Layout (auto-detected, override with WT_DIR or `git config wt.dir`):
  <repo>/.claude/worktrees/<branch>   when the repo has a .claude/ directory
  <repo>/.worktrees/<branch>          otherwise
  <WT_DIR>/<repo>/<branch>            when WT_DIR is an absolute path
HELP
      return 0
      ;;
    update)
      # Deliberately above the repo check: this updates git-wt's own clone, so
      # it must work from anywhere, including outside a repo.
      if ! git -C "$WT_HOME" pull --ff-only; then
        echo "wt: update failed. Resolve it by hand in $WT_HOME" >&2
        return 1
      fi
      # Re-source to replace this function in the CURRENT shell. Without it the
      # shell keeps running the version it loaded at startup.
      . "$WT_HOME/wt.sh"
      echo "wt updated to $(git -C "$WT_HOME" log -1 --format='%h %s')"
      echo "This shell is up to date. Other open terminals keep the old version"
      echo "until you run 'source <your rc file>' in them, or open a new one."
      return 0
      ;;
  esac

  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "wt: not inside a git repository" >&2
    return 1
  fi

  case "$cmd" in
    list | ls | "")
      git worktree list
      ;;
    new | create)
      shift
      if [ -z "${1:-}" ]; then
        echo "wt new <branch> [--no-install]" >&2
        return 1
      fi
      "$WT_HOME/lib/make-worktree.sh" "$@"
      ;;
    clean)
      shift
      "$WT_HOME/lib/cleanup-worktrees.sh" "$@"
      ;;
    root)
      cd "$(git rev-parse --git-common-dir)/.." || return 1
      pwd
      ;;
    path)
      shift
      if [ -z "${1:-}" ]; then
        echo "wt path <substring>" >&2
        return 1
      fi
      _wt_match "$1" | head -1 | cut -f1
      ;;
    *)
      # Jump. An ambiguous match is not an error: go to the first and print the
      # rest, so you can see what else matched.
      local matches target
      matches=$(_wt_match "$cmd")
      if [ -z "$matches" ]; then
        echo "wt: no worktree matching '$cmd'" >&2
        return 1
      fi
      target=$(echo "$matches" | head -1 | cut -f1)
      cd "$target" || return 1
      pwd
      if [ "$(echo "$matches" | wc -l)" -gt 1 ]; then
        echo "other matches:" >&2
        echo "$matches" | tail -n +2 | cut -f2 | sed 's/^/  /' >&2
      fi
      ;;
  esac
}

# Build a path<TAB>branch row for EVERY worktree via porcelain, so a
# detached-HEAD worktree is still reachable by path substring, then filter.
_wt_match() {
  git worktree list --porcelain | awk '
    /^worktree /{ if (p != "") print p "\t" b; p = substr($0, 10); b = "(detached)" }
    /^branch /  { b = $2; sub("refs/heads/", "", b) }
    END         { if (p != "") print p "\t" b }' \
    | grep -i -- "$1"
}
