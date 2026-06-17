#!/usr/bin/env bash
#
# first-setup.sh - run ONCE, interactively, after `docker compose up -d`:
#     docker compose exec claude first-setup.sh
#
# Two one-time steps, both landing in the persisted ~/.claude volume so you do them once:
#   1. (optional) personalisation hook - if SETUP_REPO is set, clone it and run its
#      entrypoint (e.g. to install your own dotfiles / agent-memory / a forge wrapper).
#      Unset = a plain sandbox; nothing personal is baked into the image.
#   2. interactive Claude login (subscription Pro/Max) - the one step needing a browser.
#
# Personalisation env (all optional):
#   SETUP_REPO        git URL to clone and run
#   SETUP_TOKEN       token for cloning a private SETUP_REPO (HTTP basic auth)
#   SETUP_USER        basic-auth username paired with SETUP_TOKEN (default: git)
#   SETUP_ENTRYPOINT  script in the repo to run (default: install.sh)
#   SETUP_TOKEN_FILE  if set, SETUP_TOKEN is written here (0600) before the entrypoint
#                     runs - lets a setup script that expects a token file reuse it
#   SETUP_DIR         where the setup repo is cloned (default: ~/.claude/setup)
#
# Flags: --no-login   run step 1 but skip the login (automated checks / re-running setup).
set -euo pipefail

SETUP_REPO="${SETUP_REPO:-}"
SETUP_TOKEN="${SETUP_TOKEN:-${FORGE_TOKEN:-}}"   # reuse the Forgejo token by default
SETUP_USER="${SETUP_USER:-git}"
SETUP_ENTRYPOINT="${SETUP_ENTRYPOINT:-install.sh}"
SETUP_TOKEN_FILE="${SETUP_TOKEN_FILE:-}"
SETUP_DIR="${SETUP_DIR:-$HOME/.claude/setup}"

no_login=0
[ "${1:-}" = "--no-login" ] && no_login=1

if [ -n "$SETUP_REPO" ]; then
  # Optionally stash the token where a setup script expects to read it.
  if [ -n "$SETUP_TOKEN_FILE" ] && [ -n "$SETUP_TOKEN" ]; then
    mkdir -p "$(dirname "$SETUP_TOKEN_FILE")"
    ( umask 077; printf '%s' "$SETUP_TOKEN" > "$SETUP_TOKEN_FILE" )
    chmod 600 "$SETUP_TOKEN_FILE"
    echo "Wrote token to $SETUP_TOKEN_FILE (0600)."
  fi

  if [ ! -d "$SETUP_DIR/.git" ]; then
    echo "Cloning setup repo $SETUP_REPO ..."
    auth=()
    if [ -n "$SETUP_TOKEN" ]; then
      b64="$(printf '%s' "$SETUP_USER:$SETUP_TOKEN" | base64 | tr -d '\n')"
      auth=(-c "http.extraHeader=Authorization: Basic $b64")
    fi
    git "${auth[@]}" clone --quiet "$SETUP_REPO" "$SETUP_DIR"
  fi

  entry="$SETUP_DIR/$SETUP_ENTRYPOINT"
  if [ -f "$entry" ]; then
    echo "Running setup entrypoint: $SETUP_ENTRYPOINT ..."
    SETUP_TOKEN="$SETUP_TOKEN" bash "$entry"
  else
    echo "warning: setup entrypoint not found: $entry" >&2
  fi
else
  echo "No SETUP_REPO set - plain sandbox (no personalisation)."
fi

if [ "$no_login" -eq 1 ]; then
  echo "Setup done (--no-login); skipping Claude authentication."
  exit 0
fi

echo
echo "Now authenticate Claude: run '/login', open the URL it prints on any device,"
echo "approve, paste the code back, then '/exit'. The credential is saved into ~/.claude"
echo "(the volume). Afterwards run:  docker compose restart   (brings up cc-control)."
echo
exec claude
