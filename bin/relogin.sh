#!/usr/bin/env bash
#
# relogin.sh - renew the Claude login from inside the container, without a terminal.
#
#   relogin.sh status            time left on the login (exit 0 ok, 1 = under 7 days, 2 = expired)
#   relogin.sh nag               SessionStart hook: has the session offer a renewal when one is due
#   relogin.sh start [--force]   start a login and print the OAuth URL as one line
#   relogin.sh code <code>       feed the code back, wait for the result
#   relogin.sh abort             kill a pending login
#
# The refresh token lives a FIXED 30 days from the browser login: refreshing the access
# token does not extend it, so a re-login is due every month, busy or idle.
#
# `claude auth login` needs no TTY: it prints the authorize URL on stdout and reads the
# code from stdin. So the login runs in the background with a FIFO as stdin, and any
# shell (a docker exec, or a session's Bash tool) can drive it in two steps. That is what
# lets you renew from the phone: the agent posts the URL, you paste the code.
set -euo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CRED="$CONFIG_DIR/.credentials.json"
STATE="${RELOGIN_STATE:-$CONFIG_DIR/relogin}"
FIFO="$STATE/stdin"; LOG="$STATE/log"; PID="$STATE/pid"; HOLDER="$STATE/holder"
WARN_DAYS="${RELOGIN_WARN_DAYS:-7}"
# Give up on a login nobody finishes (the authorize URL is single-use anyway).
START_TIMEOUT=30; CODE_TIMEOUT=60; LOGIN_TIMEOUT=1800

# Seconds until the refresh token lapses (negative once it has); fails if unreadable.
# Seconds, not days: whole days round the last 24 hours down to 0, which reads as expired.
secs_left() {
  local exp_ms
  exp_ms="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$CRED" 2>/dev/null)" || return 1
  case "$exp_ms" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( exp_ms / 1000 - $(date +%s) ))
}

human() { echo "$(( $1 / 86400 ))d $(( $1 % 86400 / 3600 ))h"; }

pending() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

cleanup() {
  for f in "$PID" "$HOLDER"; do
    [ -f "$f" ] && { kill "$(cat "$f")" 2>/dev/null || true; }
  done
  rm -rf "$STATE"
}

# Strip the OSC-8 hyperlink wrapper claude puts around the URL and print the URL itself.
# The escape ends in ST (ESC \) or BEL depending on the run, so split on ESC and BEL both.
# No `head`: under pipefail its early exit would SIGPIPE grep and fail a found URL.
url_from_log() {
  local urls
  urls="$(tr '\033\007' '\n\n' < "$LOG" | grep -Eo 'https://[^]\[[:space:]]+' | grep -F '/oauth/authorize')" || return 1
  printf '%s\n' "${urls%%$'\n'*}"
}

case "${1:-}" in
  status)
    s="$(secs_left)" || { echo "relogin: no readable login expiry in $CRED"; exit 2; }
    if [ "$s" -le 0 ]; then echo "Claude login has EXPIRED - renew it now."; exit 2; fi
    echo "Claude login expires in $(human "$s")."
    [ "$s" -lt $(( WARN_DAYS * 86400 )) ] && exit 1
    exit 0 ;;

  nag)
    # Silent and exit 0 unless a renewal is due, so it can never stop a session starting.
    # The context carries the whole procedure, so whichever session it lands in (not just
    # the control one, which may go unopened for weeks) can run the renewal.
    s="$(secs_left)" || exit 0
    [ "$s" -lt $(( WARN_DAYS * 86400 )) ] || exit 0
    if [ "$s" -le 0 ]; then
      # Only reachable while a session still holds an unexpired access token, so a chat
      # renewal still works - but not for long.
      when="has EXPIRED. This session is running on its last access token and may stop within hours, so this is urgent"
    else
      when="expires in $(human "$s")"
    fi
    msg="The Claude login for this container $when. It is a fixed 30-day login that cannot renew itself. In your first reply, tell the user and offer to renew it now - it takes two messages, from any device. If they agree:
1. Run \`relogin.sh start\` and send the user the URL it prints, exactly as printed.
2. Ask them to open it, approve, and paste back the code shown on the callback page.
3. Run \`relogin.sh code '<code>'\` with the code exactly as pasted, and report the result. Do not repeat the code in your reply or write it anywhere else.
If \`start\` says the login is already good, it was renewed from another session - nothing to do. If the user declines, drop it; the next session will ask again. If it cannot be done from chat, the fallback is \`docker compose exec claude reauth.sh\` on the docker host."
    jq -n --arg c "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}' || true
    exit 0 ;;

  start)
    if pending; then
      url="$(url_from_log || true)"
      if [ -n "$url" ]; then echo "relogin: a login is already pending - its URL:"; printf '%s\n' "$url"; exit 0; fi
      echo "relogin: a login is already starting - run 'relogin.sh start' again in a few seconds" >&2; exit 1
    fi
    # A stale nag (the login was renewed from another session since) should not cost the
    # user a needless re-login, so a healthy login needs --force.
    if [ "${2:-}" != "--force" ] && s="$(secs_left)" && [ "$s" -ge $(( WARN_DAYS * 86400 )) ]; then
      echo "relogin: the login is good for $(human "$s") - nothing to do (renew anyway with 'relogin.sh start --force')"
      exit 0
    fi
    cleanup; mkdir -p "$STATE"; chmod 700 "$STATE"; mkfifo -m 600 "$FIFO"; : > "$LOG"; chmod 600 "$LOG"
    # The login's open() of the FIFO blocks until a writer exists, and its stdin has to
    # stay open while it waits for the code (no writers = instant EOF). So a holder
    # process keeps the write end open; `code` writes the code (acted on as it arrives)
    # and then drops the holder. Both sides are backgrounded (each open() blocks until
    # the other end appears), every fd is redirected (a caller capturing our stdout would
    # otherwise wait on the pipe until the login exits), HUP is ignored so the caller's
    # shell can go away, and the wrapper records the exit code for `code` to read.
    ( trap '' HUP; exec sleep "$LOGIN_TIMEOUT" ) > "$FIFO" 2>/dev/null &
    ( umask 077; echo $! > "$HOLDER" )
    ( trap '' HUP; unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
      claude auth login --claudeai < "$FIFO" & cpid=$!
      ( umask 077; echo "$cpid" > "$PID" )
      rc=0; wait "$cpid" || rc=$?   # not bare: set -e would kill us before recording it
      echo "EXIT:$rc" >>"$LOG" ) </dev/null >>"$LOG" 2>&1 &
    for _ in 1 2 3 4 5; do [ -s "$PID" ] && break; sleep 0.2; done
    for _ in $(seq "$START_TIMEOUT"); do
      url="$(url_from_log || true)"
      [ -n "$url" ] && { printf '%s\n' "$url"; exit 0; }
      pending || { echo "relogin: login exited before printing a URL:" >&2; cat "$LOG" >&2; cleanup; exit 1; }
      sleep 1
    done
    echo "relogin: no URL after ${START_TIMEOUT}s:" >&2; cat "$LOG" >&2; cleanup; exit 1 ;;

  code)
    [ -n "${2:-}" ] || { echo "usage: relogin.sh code <code>" >&2; exit 1; }
    pending || { echo "relogin: no pending login - run 'relogin.sh start' first" >&2; exit 1; }
    printf '%s\n' "$2" > "$FIFO"
    kill "$(cat "$HOLDER")" 2>/dev/null || true   # drop the write end; nothing more will come
    for _ in $(seq "$CODE_TIMEOUT"); do
      if grep -q '^EXIT:' "$LOG"; then
        if grep -q '^EXIT:0$' "$LOG"; then
          cleanup; echo "Login renewed."; "$0" status || true; exit 0
        fi
        echo "relogin: login failed:" >&2; grep -v '^EXIT:' "$LOG" | tr -d '\033' | grep -iE 'fail|error' >&2 || true
        cleanup; exit 1
      fi
      sleep 1
    done
    echo "relogin: no result after ${CODE_TIMEOUT}s" >&2; cleanup; exit 1 ;;

  abort)
    cleanup; echo "relogin: aborted." ;;

  *)
    sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
