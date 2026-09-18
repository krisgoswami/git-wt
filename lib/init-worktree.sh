#!/usr/bin/env bash
# Initialise a freshly created worktree: carry over local-only env files,
# install dependencies, and keep the shared repo's `git status` clean.
# Repo-agnostic by design — it lives outside every repo it touches.
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
WT_INSTALL_DIR=$(dirname "$WT_LIB_DIR")
# shellcheck source=./common.sh
. "$WT_LIB_DIR/common.sh"

NO_INSTALL=${WT_NO_INSTALL:-false}
[ "${1:-}" = "--no-install" ] && NO_INSTALL=true

MAIN_REPO_PATH=$(wt_main_repo)
COMMON_GIT_DIR=$(wt_common_git_dir)
LAYOUT=$(wt_layout "$MAIN_REPO_PATH")

if [ ! -d "$MAIN_REPO_PATH" ]; then
  echo "Error: could not determine main repository path" >&2
  exit 1
fi

# --- 1. Local-only files the main checkout has and a fresh worktree cannot ---
# Never clobber one that already exists: a worktree may deliberately point at a
# different local database or service.
WT_ENV_FILES=${WT_ENV_FILES:-".env .env.local .env.development.local .envrc .tool-versions"}
for f in $WT_ENV_FILES; do
  if [ -f "$MAIN_REPO_PATH/$f" ] && [ ! -e "./$f" ]; then
    # Only carry over files git is not tracking; a tracked file is already here.
    if ! git -C "$MAIN_REPO_PATH" ls-files --error-unmatch "$f" > /dev/null 2>&1; then
      cp "$MAIN_REPO_PATH/$f" "./$f"
      echo "  copied $f from the main checkout"
    fi
  fi
done

# --- 2. Dependencies, detected from the lockfile rather than configured ------
# Alternatives inside one ecosystem are first-match-wins; ecosystems are
# independent, so a polyglot repo gets every one it needs. A missing tool is a
# warning, never a failure — the worktree is still usable without it.
INSTALLED_ANY=false

has_marker() {
  local m
  for m in $1; do
    case "$m" in
      *'*'*) compgen -G "$m" > /dev/null 2>&1 && return 0 ;;
      *) [ -e "$m" ] && return 0 ;;
    esac
  done
  return 1
}

# install_family <name> "<markers>|<command>"...  — runs the first match only.
install_family() {
  local family=$1 spec markers cmd tool
  shift
  for spec in "$@"; do
    markers=${spec%%|*}
    cmd=${spec#*|}
    has_marker "$markers" || continue
    INSTALLED_ANY=true
    tool=${cmd%% *}
    if [ "$tool" = "./gradlew" ]; then
      [ -x ./gradlew ] || { echo "  $family: ./gradlew is not executable — skipping"; return 0; }
    elif ! command -v "$tool" > /dev/null 2>&1; then
      echo "  $family: '$tool' not found on PATH — skipping"
      return 0
    fi
    echo "  $family: $cmd"
    eval "$cmd" || echo "  Warning: $family install failed — the worktree is still usable" >&2
    return 0
  done
}

if [ "$NO_INSTALL" = true ]; then
  echo "Skipping dependency install (--no-install)"
else
  echo "Installing dependencies..."
  install_family node \
    "pnpm-lock.yaml|pnpm install --frozen-lockfile" \
    "yarn.lock|yarn install --frozen-lockfile" \
    "bun.lockb bun.lock|bun install --frozen-lockfile" \
    "package-lock.json|npm ci"
  install_family deno "deno.lock|deno install"
  install_family python \
    "uv.lock|uv sync" \
    "poetry.lock|poetry install" \
    "Pipfile.lock|pipenv sync"
  install_family rust "Cargo.lock|cargo fetch"
  install_family go "go.mod|go mod download"
  install_family ruby "Gemfile.lock|bundle install"
  install_family php "composer.lock|composer install"
  install_family elixir "mix.lock|mix deps.get"
  # .NET writes obj/ and bin/ per directory, so a fresh worktree does need this.
  install_family dotnet "*.sln *.slnx *.csproj *.fsproj|dotnet restore"
  # JVM dependency caches are shared (~/.gradle, ~/.m2), so these only warm the
  # cache — harmless, and it keeps the first build in a new worktree honest.
  install_family gradle "gradlew|./gradlew --quiet --no-daemon dependencies"
  install_family maven "pom.xml|mvn -q -B dependency:go-offline"
  [ "$INSTALLED_ANY" = true ] || echo "  no lockfile recognised — skipping"
fi

# --- 3. Keep the shared repo's git status clean -----------------------------
# info/exclude is read from the shared common git-dir, applies to every
# worktree of this clone, and is never committed — so a repo you do not own
# stays untouched. A .gitignore edit would be a change you would have to hide.
EXCLUDE_FILE="$COMMON_GIT_DIR/info/exclude"
mkdir -p "$COMMON_GIT_DIR/info"
touch "$EXCLUDE_FILE"

add_exclude() {
  grep -qxF "$1" "$EXCLUDE_FILE" || echo "$1" >> "$EXCLUDE_FILE"
}

HEADER="# git-wt: local-only paths, never committed"
if ! grep -qxF "$HEADER" "$EXCLUDE_FILE"; then
  printf '\n%s\n' "$HEADER" >> "$EXCLUDE_FILE"
fi

case "$LAYOUT" in
  claude)
    add_exclude ".claude/worktrees/"
    add_exclude ".claude/settings.local.json"
    # Claude Code's sandbox bind-mounts /dev/null over these paths; they surface
    # as zero-byte untracked files in every `git status` otherwise. Only added
    # in Claude Code mode — nobody else should carry these lines.
    for name in .bash_profile .bashrc .gitconfig .gitmodules .mcp.json .profile .ripgreprc .zprofile .zshrc; do
      add_exclude "$name"
    done
    ;;
  default)
    add_exclude ".worktrees/"
    ;;
  external)
    # Worktrees live outside the repo; nothing to exclude.
    :
    ;;
esac

# --- 4. Optional per-repo extras --------------------------------------------
# Kept outside the repo, so a repo you do not own stays untouched.
# Named for the checkout directory; runs inside the new worktree.
REPO_NAME=$(basename "$MAIN_REPO_PATH")
if HOOK=$(wt_hook_path "$REPO_NAME" "$WT_INSTALL_DIR"); then
  echo "Running repo hook: $HOOK"
  bash "$HOOK" || {
    echo "Error: repo hook failed" >&2
    exit 1
  }
fi

echo "✓ Worktree ready"
