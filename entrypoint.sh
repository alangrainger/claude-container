#!/usr/bin/env bash
#
# claude-container entrypoint. Verifies first-setup is done, then starts and supervises
# the always-on control session (cc-control). Everything runs as the non-root `node`
# user inside the one container; ~/.claude is the persisted named volume.
#
set -euo pipefail

HOME_DIR="${HOME:-/home/node}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
CRED="$CONFIG_DIR/.credentials.json"
CFGJSON="$CONFIG_DIR/.claude.json"   # claude's config file lives here (CLAUDE_CONFIG_DIR)
CONTROL_TMUX="cc-control"
# cc-control's web name. By default it is "<WEB_NAME_PREFIX> 🛠️ Control" (the same prefix
# the launcher puts on session names), so the prefix is set once in the env; an explicit
# CONTROL_NAME overrides it entirely.
WEB_NAME_PREFIX="${WEB_NAME_PREFIX:-}"
if [ -z "${CONTROL_NAME:-}" ]; then
  if [ -n "$WEB_NAME_PREFIX" ]; then CONTROL_NAME="$WEB_NAME_PREFIX 🛠️ Control"; else CONTROL_NAME="🛠️ Control"; fi
fi
# Run the control session in its OWN dir under the workspace, NOT $HOME and NOT the
# workspace root: keeps it off the secrets in ~/.claude, distinct from the
# $WORKDIR/<name> project dirs (no bridge-pointer collision), and - crucially - lets us
# drop a CLAUDE.md here that tells the control agent how to launch sessions WITHOUT that
# CLAUDE.md leaking into the repo sessions it spawns (it is a sibling, not a parent).
CONTROL_DIR="${CONTROL_DIR:-${WORKDIR:-/workspace}/.control}"
PERMISSION_MODE="${PERMISSION_MODE:-acceptEdits}"

# API keys are not supported for Remote Control; never let one through.
unset ANTHROPIC_API_KEY

# ~/.claude must be writable by the container user (uid 1000 `node`), and must contain the
# .config/.local dirs the read-only rootfs symlinks ~/.config and ~/.local into (see
# Dockerfile). Named volumes are seeded from the image and owned correctly, so this is a
# no-op for them. Bind mounts are NOT seeded (an empty host dir just overlays the path), so
# recreate the dirs. Most runtimes make the mount writable by the container user
# automatically (Docker Desktop/OrbStack map it; rootless Podman with keep-id maps your
# user to `node`); the exception is rootful Docker, which auto-creates a missing bind dir
# as root:root. We can't chown from in here (hardened: no caps), so if the mount is
# unwritable, stop with a clear, runtime-specific hint rather than failing confusingly
# later (e.g. a setup hook's mkdir ~/.config).
mkdir -p "$CONFIG_DIR/.config" "$CONFIG_DIR/.local/bin" 2>/dev/null || true
if ! ( : > "$CONFIG_DIR/.writable" ) 2>/dev/null; then
  cat <<EOF
claude-container: $CONFIG_DIR is not writable by the container user (uid 1000 'node').
A bind mount must be writable by that user. Depending on your runtime:
  - rootful Docker:   the dir was created root:root - 'sudo chown -R 1000:1000 <host dir>'
  - rootless Podman:  use keep-id, e.g. compose 'userns_mode: keep-id:uid=1000,gid=1000'
  - Docker Desktop / OrbStack: shouldn't happen - double-check the mount path exists
Named volumes avoid this entirely. Idling so the container stays up...
EOF
  exec sleep infinity
fi
rm -f "$CONFIG_DIR/.writable"

# First-setup gate: without a credential, claude cannot start. Keep the container alive
# (so `docker compose exec` works) and print exactly what to run.
if [ ! -s "$CRED" ]; then
  cat <<EOF
claude-container: first-setup not complete - no credential at ~/.claude/.credentials.json
Run this once (optional personalisation + Claude login, into the volume):

    docker compose exec claude first-setup.sh

Idling so you can exec in...
EOF
  exec sleep infinity
fi

# cc-control bypasses the launcher, so trust its working dir directly (remote-control
# refuses an untrusted workspace and cannot answer the dialog headlessly).
trust_dir() {
  local f="$CFGJSON" tmp
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$f" ] || printf '{}\n' > "$f"
  tmp="$(mktemp "${f}.XXXXXX")" || return 0
  if jq --arg d "$1" '.projects[$d].hasTrustDialogAccepted = true' "$f" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# Pre-accept the one-time "Enable Remote Control? (y/n)" consent so a headless launch on
# a fresh volume doesn't hang waiting for input. Recorded in ~/.claude.json (volume),
# the same flag the interactive prompt sets; enabling remote-control IS the point here.
accept_remote_control() {
  local f="$CFGJSON" tmp
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$f" ] || printf '{}\n' > "$f"
  tmp="$(mktemp "${f}.XXXXXX")" || return 0
  if jq '.remoteDialogSeen = true' "$f" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

launch_control() {
  tmux new-session -d -s "$CONTROL_TMUX" -c "$CONTROL_DIR" \
    "exec env -u ANTHROPIC_API_KEY claude remote-control \
       --spawn session \
       --name $(printf '%q' "$CONTROL_NAME") \
       --permission-mode $(printf '%q' "$PERMISSION_MODE")"
}

# Archive any stale bridge-pointer so claude mints a fresh web-session link.
# The pointer persists in the bind-mounted ~/.claude but always refers to a
# dead process after a container restart or session crash, never a live one.
clear_control_bridge_pointer() {
  local slug bp
  slug="$(printf '%s' "$CONTROL_DIR" | sed 's#[^A-Za-z0-9]#-#g')"
  bp="$CONFIG_DIR/projects/$slug/bridge-pointer.json"
  [ -f "$bp" ] || return 0
  mv "$bp" "$bp.stale" 2>/dev/null \
    && echo "claude-container: archived stale control bridge-pointer (fresh web link will be minted)"
}

mkdir -p "$CONTROL_DIR" 2>/dev/null || true
# Install the control instructions so the agent knows it can launch sessions.
cp -f /usr/local/share/control-CLAUDE.md "$CONTROL_DIR/CLAUDE.md" 2>/dev/null || true
accept_remote_control
trust_dir "$CONTROL_DIR"
tmux start-server 2>/dev/null || true
echo "claude-container: starting control session ($CONTROL_TMUX -> \"$CONTROL_NAME\") in $CONTROL_DIR"
clear_control_bridge_pointer
launch_control || true

# Mention poller: watch Forgejo notifications for @mentions and dispatch to sessions.
if [ "${ENABLE_MENTION_POLLER:-0}" = "1" ]; then
  echo "claude-container: starting mention poller (interval: ${MENTION_POLLER_INTERVAL:-30}s)"
  ( while true; do
      mention-poller.sh || true
      echo "claude-container: mention poller exited - restarting in 10s"
      sleep 10
    done ) &
fi

# Supervise: keep cc-control alive (it is the always-on console you launch others from)
# and keep the container running. A dead control session is relaunched.
while true; do
  if ! tmux has-session -t "=$CONTROL_TMUX" 2>/dev/null; then
    echo "claude-container: control session gone - relaunching"
    clear_control_bridge_pointer
    launch_control || true
  fi
  sleep 15
done
