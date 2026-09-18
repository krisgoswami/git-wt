#!/bin/sh
# Shared helpers for git-wt. POSIX sh on purpose: this file is sourced by the
# bash scripts in lib/ and by wt.sh under both bash and zsh.

# --- portable realpath ------------------------------------------------------
# `readlink -f` is GNU-only and is missing from stock macOS, and `realpath(1)`
# only arrived in recent macOS. Resolve by hand instead so there is nothing to
# detect and nothing to install.
wt_realpath() {
  wt__target=$1
  [ -n "$wt__target" ] || return 1
  wt__n=0
  while [ -L "$wt__target" ] && [ "$wt__n" -lt 40 ]; do
    wt__link=$(readlink "$wt__target")
    case "$wt__link" in
      /*) wt__target=$wt__link ;;
      *)  wt__target=$(dirname "$wt__target")/$wt__link ;;
    esac
    wt__n=$((wt__n + 1))
  done
  wt__dir=$(dirname "$wt__target")
  wt__base=$(basename "$wt__target")
  wt__dir=$(cd "$wt__dir" 2> /dev/null && pwd -P) || return 1
  case "$wt__base" in
    .)  printf '%s\n' "$wt__dir" ;;
    ..) (cd "$wt__dir/.." 2> /dev/null && pwd -P) ;;
    /)  printf '/\n' ;;
    *)  printf '%s\n' "${wt__dir%/}/$wt__base" ;;
  esac
}

# Directory holding a script, with symlinks resolved — the clone itself may sit
# behind a symlink, and the lib/ a script must find is next to the real file.
wt_script_dir() {
  dirname "$(wt_realpath "$1")"
}

# --- repo detection ---------------------------------------------------------
wt_require_repo() {
  git rev-parse --is-inside-work-tree > /dev/null 2>&1 || {
    echo "git-wt: not inside a git repository" >&2
    return 1
  }
}

# The main checkout, i.e. the parent of the shared common git-dir. Correct from
# inside a linked worktree too, where --git-dir points at .git/worktrees/<name>.
wt_main_repo() {
  wt__gcd=$(git rev-parse --git-common-dir 2> /dev/null) || return 1
  (cd "$wt__gcd/.." 2> /dev/null && pwd -P)
}

wt_common_git_dir() {
  wt__gcd=$(git rev-parse --git-common-dir 2> /dev/null) || return 1
  (cd "$wt__gcd" 2> /dev/null && pwd -P)
}

# --- layout -----------------------------------------------------------------
# Three layouts, one auto-detected default. See README "Where worktrees live".
#
#   claude    <repo>/.claude/worktrees/<branch>   when .claude/ exists
#   default   <repo>/.worktrees/<branch>
#   external  <WT_DIR>/<repo-name>/<branch>       when WT_DIR is absolute
#
# The dot prefix is load bearing: hidden directories are skipped by default by
# ripgrep, pytest, ESLint and most file watchers, so an in-repo worktree does
# not give you duplicate search hits and doubled test collection.
wt_layout() {
  wt__main=$1
  wt__dir=${WT_DIR:-$(git config --get wt.dir 2> /dev/null || true)}
  if [ -n "$wt__dir" ]; then
    echo external
    return 0
  fi
  wt__forced=${WT_LAYOUT:-$(git config --get wt.layout 2> /dev/null || true)}
  case "$wt__forced" in
    claude|default|external)
      echo "$wt__forced"
      return 0
      ;;
    "") ;;
    *)
      echo "git-wt: unknown layout '$wt__forced' (want claude, default or external)" >&2
      return 1
      ;;
  esac
  if [ -d "$wt__main/.claude" ]; then echo claude; else echo default; fi
}

# The directory worktrees are created under, for a given main checkout.
wt_base_dir() {
  wt__main=$1
  wt__layout=$(wt_layout "$wt__main") || return 1
  case "$wt__layout" in
    external)
      wt__dir=${WT_DIR:-$(git config --get wt.dir 2> /dev/null || true)}
      case "$wt__dir" in
        /*) ;;
        "")
          echo "git-wt: layout 'external' needs WT_DIR (or git config wt.dir)" >&2
          return 1
          ;;
        *)
          echo "git-wt: WT_DIR must be an absolute path, got '$wt__dir'" >&2
          return 1
          ;;
      esac
      printf '%s/%s\n' "${wt__dir%/}" "$(basename "$wt__main")"
      ;;
    claude)  printf '%s/.claude/worktrees\n' "$wt__main" ;;
    *)       printf '%s/.worktrees\n' "$wt__main" ;;
  esac
}

# --- default branch ---------------------------------------------------------
# origin/HEAD is unset on many clones, so never assume main. Prints a remote
# ref such as "origin/main"; falls back to HEAD with a loud warning.
wt_default_ref() {
  wt__ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2> /dev/null || true)
  if [ -n "$wt__ref" ]; then
    printf '%s\n' "${wt__ref#refs/remotes/}"
    return 0
  fi
  for wt__c in origin/main origin/master origin/develop; do
    if git rev-parse --verify --quiet "$wt__c" > /dev/null 2>&1; then
      printf '%s\n' "$wt__c"
      return 0
    fi
  done
  return 1
}

wt_warn_no_default_ref() {
  echo "Warning: no origin/HEAD and no origin/main|master|develop." >&2
  echo "         Fix it once with: git remote set-head origin --auto" >&2
}

# --- branch name validation -------------------------------------------------
# The worktree path is assembled before git ever sees the name, so "../.." has
# to be rejected here or it escapes the worktree directory.
wt_check_branch_name() {
  wt__b=$1
  case "$wt__b" in
    "")
      echo "git-wt: empty branch name" >&2
      return 1
      ;;
  esac
  # POSIX-portable character check: no bash [[ =~ ]], no GNU grep flags.
  case "$wt__b" in
    *[!a-zA-Z0-9._/-]*)
      echo "git-wt: invalid branch name '$wt__b'" >&2
      echo "        use alphanumerics, dots, hyphens, underscores, and / for a prefix" >&2
      return 1
      ;;
  esac
  case "/$wt__b/" in
    */../* | */./* | *//*)
      echo "git-wt: branch name must not contain '.', '..' or empty path segments" >&2
      return 1
      ;;
  esac
  case "$wt__b" in
    -*)
      echo "git-wt: branch name must not start with '-'" >&2
      return 1
      ;;
  esac
  return 0
}

# --- hooks ------------------------------------------------------------------
# Per-repo hooks live OUTSIDE the repo, so a repo you do not own stays
# untouched. User hooks come first; the ones shipped in the checkout are a
# fallback, mainly so the repo can carry examples.
wt_hook_path() {
  wt__repo_name=$1
  wt__install=$2
  wt__user_dir=${WT_HOOKS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/git-wt/hooks}
  for wt__cand in "$wt__user_dir/$wt__repo_name.sh" "$wt__install/hooks/$wt__repo_name.sh"; do
    if [ -f "$wt__cand" ]; then
      printf '%s\n' "$wt__cand"
      return 0
    fi
  done
  return 1
}
