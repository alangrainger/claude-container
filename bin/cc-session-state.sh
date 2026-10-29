#!/usr/bin/env bash
#
# cc-session-state.sh - Claude Code hook target that keeps a busy flag on the tmux
# session claude runs in, so the forge poller knows when it may type an event into
# the session's chat input. The screen is no use for this: while claude streams text
# the pane shows no busy marker at all.
#
# Wired in the image's managed settings (Dockerfile):
#   UserPromptSubmit, PreToolUse  -> busy    a turn is running
#   Stop, SessionStart, SessionEnd -> idle   the turn is over / nothing is running
#   Notification                   -> notify idle only for claude's "waiting for your
#                                            input" notice (backstop: Stop does not fire
#                                            after a user interrupt)
#
# The flag is the tmux session option @cc_busy (1 = busy, unset = idle), read by
# mention-poller.sh. It lives with the session and dies with it, so nothing is stored.
# Outside tmux (a session started by hand in a shell) this does nothing. Always exits 0:
# a hook failure must never block claude.
[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
session="$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null)" || exit 0
[ -n "$session" ] || exit 0

case "${1:-}" in
  busy)   tmux set-option -t "=$session:" @cc_busy 1 2>/dev/null ;;
  idle)   tmux set-option -u -t "=$session:" @cc_busy 2>/dev/null ;;
  notify)
    # Hook input (JSON on stdin) carries the notification type. Only the idle notice
    # means the prompt is free; a permission or question dialog is still mid-turn.
    if command -v jq >/dev/null 2>&1 \
       && jq -e '(.notification_type // "") == "idle_prompt" or ((.message // "") | test("waiting for your input"))' >/dev/null 2>&1; then
      tmux set-option -u -t "=$session:" @cc_busy 2>/dev/null
    fi ;;
esac
exit 0
