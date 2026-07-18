#!/usr/bin/env bash
#
# reauth.sh - re-authenticate an expired Claude login, in place:
#     docker compose exec claude reauth.sh          # start/attach the login session
#     docker compose exec claude reauth.sh --url    # print the OAuth URL, unwrapped
#
# Unlike first-setup.sh this does the login ONLY - no SETUP_REPO clone, no setup
# entrypoint - so it is safe to run against an already-personalised volume.
#
# The one real friction in re-auth is copying the OAuth URL: it wraps across terminal
# rows, and a wrapped URL cannot be mouse-selected cleanly (doubly so over SSH into the
# docker host). So `claude` runs inside a tmux session with a deliberately wide pane, and
# `--url` reads the URL back with `capture-pane -J`, which joins wrapped lines - printing
# it as one unbroken string you can copy in a single go.
#
# You drive the TUI yourself. An earlier version sent the keystrokes too (send-keys
# "/login", answer the account-picker, poll for the URL); it broke whenever the login flow
# changed, and when it broke it did so blind - a timeout with no URL and no clue why.
# Reading the pane is the part worth automating; typing into it is not.
set -euo pipefail

SESSION="${REAUTH_TMUX:-cc-login}"
# Wide enough that the URL never wraps. Not arbitrary: an observed authorize URL was
# exactly 400 chars before the &state= tail, so 200 (and even 400) wrapped it. The URL
# grows with the scope list, so leave generous headroom rather than tracking it.
PANE_WIDTH="${REAUTH_PANE_WIDTH:-1000}"
PANE_HEIGHT="${REAUTH_PANE_HEIGHT:-50}"

pane() { tmux capture-pane -p -J -t "=$SESSION" 2>/dev/null || true; }

session_exists() { tmux has-session -t "=$SESSION" 2>/dev/null; }

# Widen the window so claude re-renders the URL on a single line.
#
# Two things conspire against reading the URL back. First, `tmux attach` resizes the
# session to the attaching client, so the wide pane set at new-session time is gone the
# moment you attach - claude re-wraps to your real terminal width. 'window-size manual'
# is what stops that. Second, claude's TUI wraps with REAL newlines at its render width,
# not terminal-level wrapping, so capture-pane -J has nothing to rejoin: -J only glues
# back rows that tmux itself wrapped. Hence widen-then-redraw rather than widen-then-join.

# window-size is a WINDOW option, so it needs -w; older tmux wants it unscoped. Try both
# rather than let the wrong form fail silently and leave the resize to be undone on the
# next attach.
set_window_size() {
  tmux set-option -w -t "=$SESSION" window-size "$1" 2>/dev/null \
    || tmux set-option -t "=$SESSION" window-size "$1" 2>/dev/null \
    || true
}

widen() {
  set_window_size manual
  tmux resize-window -t "=$SESSION" -x "$PANE_WIDTH" -y "$PANE_HEIGHT" 2>/dev/null || true
  sleep 1   # let claude handle SIGWINCH and repaint
}

# Fallback for if the TUI caps its box width and wraps even in a wide window: stitch the
# URL back from consecutive unbroken lines. A URL fragment is the only thing on its line,
# so append space-free lines until one contains whitespace or is blank.
reassemble() {
  awk '
    BEGIN { u = ""; joining = 0 }
    {
      if (joining) {
        if ($0 ~ /^[^[:space:]]+$/) { u = u $0; next }
        joining = 0
      }
      i = index($0, "https://")
      if (i > 0 && u == "") {
        u = substr($0, i)
        if (u ~ /[[:space:]]/) { sub(/[[:space:]].*/, "", u) } else { joining = 1 }
      }
    }
    END { print u }
  '
}

# --url: print the OAuth URL currently on screen. Run this from a second shell, or
# detach first (Ctrl-b then d) and run it from the same one.
if [ "${1:-}" = "--url" ]; then
  if ! session_exists; then
    echo "reauth: no login session '$SESSION' - start one first: reauth.sh" >&2
    exit 1
  fi
  widen
  url="$(pane | grep -Eo 'https://[^[:space:]]*(oauth|authorize)[^[:space:]]*' | tail -1)" || true
  # Take whichever is longer: a truncated single line loses to the stitched version, and
  # a correct single line is never shorter than what reassemble() produces from it.
  joined="$(pane | reassemble)" || true
  [ "${#joined}" -gt "${#url}" ] && url="$joined"
  if [ -z "$url" ]; then
    cat >&2 <<EOF
reauth: no OAuth URL on screen yet.
Attach (reauth.sh) and run /login - the URL appears after you pick the account type.
EOF
    exit 1
  fi
  printf '%s\n' "$url"
  exit 0
fi

# Undo widen()'s manual sizing before handing the session back to a human. Left set,
# tmux stops fitting the window to the attaching client and you get a small viewport onto
# a 1000-column window - unusable for pasting the code back in.
unwiden() { set_window_size latest; }

# Reuse a live session so you can detach, grab the URL, and come back to the same prompt.
if session_exists; then
  echo "reauth: attaching to existing login session '$SESSION'"
else
  echo "reauth: starting claude in tmux session '$SESSION' ..."
  tmux new-session -d -s "$SESSION" -x "$PANE_WIDTH" -y "$PANE_HEIGHT" "claude"
  sleep 3
  # If claude exits immediately (bad install, unreadable config) the session is already
  # gone. Say so here rather than dumping the user into a dead attach.
  if ! session_exists; then
    echo "reauth: claude exited immediately - the login session died on startup." >&2
    echo "reauth: try 'claude' directly to see the error." >&2
    exit 1
  fi
fi

cat <<EOF

You are about to attach to the login session. In it:

  1. Run  /login  and pick your account type.
  2. Wait for the OAuth URL to appear on screen.
  3. Press Ctrl-b then d to detach (this leaves claude running).
  4. Print the URL as one copyable line:

         docker compose exec claude reauth.sh --url

  5. Approve it on any device, then come back with  reauth.sh  and paste the code.

EOF
printf 'Press Enter to attach... '
read -r _

# Both branches land here, so restore the sizing once, unconditionally: a session that
# was widened by an earlier --url run is still manual, and attaching to it gives a
# viewport onto a 1000-column window rather than a pane fitted to your terminal.
unwiden
tmux attach -t "=$SESSION"

cat <<EOF

reauth: detached from the login session.
  - grab the URL:   docker compose exec claude reauth.sh --url
  - go back to it:  docker compose exec claude reauth.sh

Once the code is pasted and the login is confirmed, the credential is saved into
~/.claude (the volume). Then bring the control session back up:

    docker compose restart

EOF
