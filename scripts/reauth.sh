#!/usr/bin/env bash
#
# reauth.sh - re-authenticate an expired Claude login, in place:
#     docker compose exec claude reauth.sh
#
# Unlike first-setup.sh this does the login ONLY - no SETUP_REPO clone, no setup
# entrypoint - so it is safe to run against an already-personalised volume.
#
# The one real friction in re-auth is copying the OAuth URL: it wraps across terminal
# rows, and a wrapped URL cannot be mouse-selected cleanly (doubly so over SSH into the
# docker host). So we drive `claude` inside a detached tmux session with a deliberately
# wide pane, then read the URL back with `capture-pane -J`, which joins wrapped lines.
# The URL is printed as one unbroken string you can copy in a single go.
set -euo pipefail

SESSION="${REAUTH_TMUX:-cc-login}"
PANE_WIDTH="${REAUTH_PANE_WIDTH:-200}"   # wide pane: the URL often doesn't wrap at all
PANE_HEIGHT="${REAUTH_PANE_HEIGHT:-50}"
TIMEOUT="${REAUTH_TIMEOUT:-60}"          # seconds to wait for the URL to appear

# A stale login session from a previous attempt would swallow our send-keys.
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  echo "reauth: killing stale tmux session '$SESSION'"
  tmux kill-session -t "=$SESSION" 2>/dev/null || true
fi

# Read the pane as one string. -J joins wrapped lines, so a URL split across rows
# comes back unbroken - the whole reason we drive this through tmux.
pane() { tmux capture-pane -p -J -t "$SESSION" 2>/dev/null || true; }

# Poll the pane for an extended regex; returns 0 as soon as it matches.
wait_for() {
  local re="$1" limit="$2" i
  for i in $(seq 1 "$limit"); do
    pane | grep -Eq "$re" && return 0
    sleep 1
  done
  return 1
}

echo "reauth: starting claude in tmux session '$SESSION' ..."
tmux new-session -d -s "$SESSION" -x "$PANE_WIDTH" -y "$PANE_HEIGHT" "claude"

# Wait for the TUI to actually paint its input box - a fixed sleep either races the
# slow case (cold start on a loaded host) or wastes time on the fast one.
wait_for '>|Welcome|bypass permissions' 30 || echo "reauth: WARNING - claude's prompt never appeared; typing anyway"
sleep 1
tmux send-keys -t "$SESSION" "/login"
# Typing a slash command opens the autocomplete popup, and the first Enter is consumed
# by it (accepting the highlighted entry) rather than submitting. Send Enter, and if the
# login menu hasn't appeared shortly after, send the one that actually submits.
sleep 1
tmux send-keys -t "$SESSION" Enter

# /login does NOT go straight to the browser handoff: it first asks
#   Select login method:
#     > Claude account with subscription
#       Anthropic Console account
# and prints no URL until a choice is confirmed. Without this the poll below just
# times out staring at the menu.
if ! wait_for 'Select login method' 5; then
  tmux send-keys -t "$SESSION" Enter
  wait_for 'Select login method' 15 || echo "reauth: WARNING - login menu never appeared"
fi
# "Claude account with subscription" is the default highlighted option, which is the
# one that belongs in this container; accept it.
tmux send-keys -t "$SESSION" Enter

echo "reauth: waiting for the OAuth URL (up to ${TIMEOUT}s) ..."
url=""
for _ in $(seq 1 "$TIMEOUT"); do
  url="$(pane | grep -Eo 'https://[^[:space:]]*(oauth|authorize)[^[:space:]]*' | tail -1)"
  [ -n "$url" ] && break
  sleep 1
done

echo
if [ -n "$url" ]; then
  cat <<EOF
Open this URL on any device, approve, and copy the code it gives you:

$url

EOF
else
  cat <<EOF
reauth: could not read the URL automatically within ${TIMEOUT}s.
Attach and read it off the screen instead; from another shell you can also run:

    tmux capture-pane -p -J -t $SESSION | grep -Eo 'https://[^ ]+'

EOF
fi

echo "Attaching - paste the code at the prompt, then '/exit'. (Detach: Ctrl-b then d)"
echo
tmux attach -t "$SESSION"

cat <<EOF

reauth: login session closed. The credential is saved into ~/.claude (the volume).
Now bring the control session back up:

    docker compose restart

EOF
