#!/usr/bin/env sh
# Installs git-wt by linking bin/git-wt onto PATH and telling you the one line
# to add to your rc file. It does NOT edit your rc file unless you ask with
# --write-rc: a tool that silently rewrites your shell config is a tool you
# cannot audit.
set -eu

_self=$0
while [ -L "$_self" ]; do
  _link=$(readlink "$_self")
  case "$_link" in
    /*) _self=$_link ;;
    *)  _self=$(dirname "$_self")/$_link ;;
  esac
done
WT_HOME=$(cd "$(dirname "$_self")" && pwd -P)

BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
WRITE_RC=false
RC_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --write-rc) WRITE_RC=true; shift ;;
    --rc) RC_FILE=${2:-}; WRITE_RC=true; shift 2 ;;
    --bin-dir) BIN_DIR=${2:-}; shift 2 ;;
    -h | --help)
      cat <<'HELP'
Usage: ./install.sh [--write-rc] [--rc <file>] [--bin-dir <dir>]

  --write-rc     append the `source` line to your shell rc file
  --rc <file>    which rc file to append to (implies --write-rc)
  --bin-dir DIR  where to link git-wt (default: ~/.local/bin)
HELP
      exit 0
      ;;
    *)
      echo "install.sh: unknown option '$1'" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$BIN_DIR"
ln -sf "$WT_HOME/bin/git-wt" "$BIN_DIR/git-wt"
echo "Linked $BIN_DIR/git-wt -> $WT_HOME/bin/git-wt"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH, so 'git wt' will not be found yet." ;;
esac

SOURCE_LINE=". \"$WT_HOME/wt.sh\""

# Which rc file actually gets read is not just a shell question, it is an OS
# question. zsh reads .zshrc for every interactive shell, so that one is easy.
# bash reads .bashrc for interactive non-login shells and .bash_profile for
# login shells — and macOS Terminal opens a LOGIN shell for every new window,
# so .bashrc there is a file that is never read.
if [ -z "$RC_FILE" ]; then
  case "${SHELL:-}" in
    *zsh) RC_FILE=${ZDOTDIR:-$HOME}/.zshrc ;;
    *)
      if [ "$(uname -s 2> /dev/null || echo unknown)" = Darwin ]; then
        RC_FILE=$HOME/.bash_profile
      else
        RC_FILE=$HOME/.bashrc
      fi
      ;;
  esac
fi

if [ "$WRITE_RC" = true ]; then
  if [ -f "$RC_FILE" ] && grep -qF "$WT_HOME/wt.sh" "$RC_FILE"; then
    echo "Already sourced from $RC_FILE — nothing to do."
  else
    printf '\n# git-wt\n%s\n' "$SOURCE_LINE" >> "$RC_FILE"
    echo "Appended the source line to $RC_FILE"
  fi
else
  echo ""
  echo "Add this line to $RC_FILE (or re-run with --write-rc):"
  echo ""
  echo "    $SOURCE_LINE"
  echo ""
fi

echo "Then: exec \$SHELL  —  and try 'wt help'"
