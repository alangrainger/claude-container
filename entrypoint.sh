#!/usr/bin/env bash
#
# claude-container entrypoint. Verifies first-setup is done, then starts and supervises
# the always-on control session (cc-control). Everything runs as the non-root `node`
# user inside the one container; ~/.claude is the persisted named volume.
#
set -euo pipefail

# Every container log line carries a local timestamp (TZ from .env, else UTC).
log() { printf '%s claude-container: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }

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

# Expiry gate. A credential can be present and non-empty but dead, in which case the
# check above passes and cc-control fails to start with no explanation - the container
# looks healthy while nothing works.
#
# Note WHICH field: .expiresAt is the short-lived access token (~8h, refreshed
# constantly) and gating on it would false-alarm many times a day. The boundary that
# actually forces a browser login is .refreshTokenExpiresAt: a fixed 30 days from the
# browser login, which refreshing does NOT extend. When it lapses, auth dies silently -
# exactly the case worth catching. Both fields are epoch MILLISECONDS.
#
# This is a diagnostic, so it must never be the reason startup fails: any missing jq,
# absent field, or unparseable value just skips the check.
check_credential_expiry() {
  command -v jq >/dev/null 2>&1 || return 0
  local exp_ms now_s exp_s left_d
  exp_ms="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$CRED" 2>/dev/null)" || return 0
  case "$exp_ms" in ''|*[!0-9]*) return 0 ;; esac   # absent or non-numeric: skip
  now_s="$(date +%s)"
  exp_s=$(( exp_ms / 1000 ))

  if [ "$exp_s" -le "$now_s" ]; then
    cat <<EOF
claude-container: the Claude login has EXPIRED (refresh token lapsed).
Re-authenticate (login only - does not re-run your setup repo):

    docker compose exec claude reauth.sh

then:  docker compose restart

Idling so you can exec in...
EOF
    exec sleep infinity
  fi

  # Still valid - warn early, while there is time to act without being locked out.
  left_d=$(( (exp_s - now_s) / 86400 ))
  if [ "$left_d" -le 3 ]; then
    log "WARNING - Claude login expires in ~${left_d}d. Run 'docker compose exec claude reauth.sh' to renew."
  fi
}
check_credential_expiry

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

# CONTROL_DEBUG=1 adds claude's own debug log at this path (tmpfs, gone on restart).
CONTROL_DEBUG_FILE="/tmp/cc-control-debug.log"

# remain-on-exit is chained onto new-session in the same tmux command sequence, so it
# is set before tmux can reap the pane even if claude dies at once. A dead pane is kept
# with its last screen, which the supervisor logs (see log_control_exit) - otherwise the
# reason claude exited vanishes with the session. The pane is 250 columns wide because
# claude's UI erases and redraws its lines by count: a message that wraps at the default
# 80 columns is partly erased on exit, leaving only its last few words on screen.
launch_control() {
  local debug=""
  [ "${CONTROL_DEBUG:-0}" = "1" ] && debug="--debug-file $(printf '%q' "$CONTROL_DEBUG_FILE")"
  tmux new-session -d -s "$CONTROL_TMUX" -c "$CONTROL_DIR" -x 250 -y 50 \
    "exec env -u ANTHROPIC_API_KEY claude remote-control \
       --spawn session \
       --name $(printf '%q' "$CONTROL_NAME") \
       --permission-mode $(printf '%q' "$PERMISSION_MODE") $debug" \; \
    set-option -w remain-on-exit on
}

# Log why cc-control died: exit status plus the last lines claude left on screen. A
# crash loop repeats the same screen every 15s, so the tail is logged only when it
# changes; repeats get one line.
last_control_tail=""
log_control_exit() {
  local status tail
  status="$(tmux list-panes -t "=$CONTROL_TMUX" -F '#{pane_dead_status}' 2>/dev/null | head -n 1 || true)"
  tail="$(tmux capture-pane -p -J -S -200 -t "=$CONTROL_TMUX:" 2>/dev/null \
    | grep -v -e '^[[:space:]]*$' -e '^Pane is dead' | tail -n 20 || true)"
  if [ "$tail" = "$last_control_tail" ]; then
    log "control session exited (status ${status:-?}) - same output as last time"
  else
    log "control session exited (status ${status:-?}) - last output:"
    printf '%s\n' "${tail:-(no output)}" | sed 's/^/    | /'
    last_control_tail="$tail"
  fi
  [ "${CONTROL_DEBUG:-0}" = "1" ] && log "debug log: $CONTROL_DEBUG_FILE"
  tmux kill-session -t "=$CONTROL_TMUX" 2>/dev/null || true
}

# Claude Code keeps a working dir's Remote Control environment id in
# ~/.claude/projects/<dir-slug>/bridge-pointer.json and asks the server to REUSE that
# environment on the next launch in that dir. Never archive or delete it: a fresh
# registration for a folder the server still sees as served (e.g. after a container was
# killed before claude could deregister) is refused with "This folder is already served
# by another Claude Code on this device. Stop it first." Older versions of this script
# archived the pointer to bridge-pointer.json.stale; restore_bridge_pointer moves such an
# archive back so claude can reclaim its environment. Claude drops a pointer that is too
# old by itself.
restore_bridge_pointer() {
  local slug bp
  slug="$(printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g')"
  bp="$CONFIG_DIR/projects/$slug/bridge-pointer.json"
  [ ! -f "$bp" ] && [ -f "$bp.stale" ] || return 0
  if mv "$bp.stale" "$bp" 2>/dev/null; then
    log "restored archived bridge-pointer for $1 (claude will reuse its environment)"
  fi
}

# Stop every claude session cleanly when the container stops (compose down/restart send
# SIGTERM, then SIGKILL after 10s). A killed claude never deregisters its Remote Control
# environment, so the server keeps the folder marked as served. Each pane runs claude
# directly (exec), so its pane pid is claude.
shutdown_sessions() {
  local pids i
  log "stopping - asking claude sessions to shut down cleanly"
  pids="$(tmux list-panes -a -F '#{pane_dead} #{pane_pid}' 2>/dev/null | awk '$1==0{print $2}')"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    for i in $(seq 1 16); do
      # shellcheck disable=SC2086
      kill -0 $pids 2>/dev/null || break
      sleep 0.5
    done
  fi
  tmux kill-server 2>/dev/null || true
  exit 0
}

mkdir -p "$CONTROL_DIR" 2>/dev/null || true
# Install the control instructions so the agent knows it can launch sessions.
cp -f /usr/local/share/control-CLAUDE.md "$CONTROL_DIR/CLAUDE.md" 2>/dev/null || true
accept_remote_control
trust_dir "$CONTROL_DIR"
tmux start-server 2>/dev/null || true
log "starting control session ($CONTROL_TMUX -> \"$CONTROL_NAME\") in $CONTROL_DIR"
restore_bridge_pointer "$CONTROL_DIR"
trap shutdown_sessions TERM INT
launch_control || true

# Forge poller: dispatch Forgejo @mentions and/or passed issue due dates to sessions.
if [ "${ENABLE_MENTION_POLLER:-0}" = "1" ] || [ "${ENABLE_DUE_WAKEUP:-0}" = "1" ]; then
  log "starting forge poller (mentions: ${ENABLE_MENTION_POLLER:-0}, due wake-ups: ${ENABLE_DUE_WAKEUP:-0}, interval: ${MENTION_POLLER_INTERVAL:-30}s)"
  ( while true; do
      mention-poller.sh || true
      log "forge poller exited - restarting in 10s"
      sleep 10
    done ) &
fi

# Supervise: keep cc-control alive (it is the always-on console you launch others from)
# and keep the container running. A dead control session is relaunched.
while true; do
  # tmux 3.4's display-message succeeds with empty output for a missing session, so
  # existence comes from has-session and the dead flag from list-panes.
  dead=gone
  if tmux has-session -t "=$CONTROL_TMUX" 2>/dev/null; then
    dead="$(tmux list-panes -t "=$CONTROL_TMUX" -F '#{pane_dead}' 2>/dev/null | head -n 1 || true)"
  fi
  if [ "$dead" = "1" ]; then
    log_control_exit
    dead=gone
  fi
  if [ "$dead" = "gone" ]; then
    log "control session gone - relaunching"
    launch_control || true
  fi
  # Background sleep + wait, so a stop signal runs the trap at once rather than after
  # the sleep ends.
  sleep 15 & wait $! || true
done
