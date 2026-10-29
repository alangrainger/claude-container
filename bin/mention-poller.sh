#!/usr/bin/env bash
# mention-poller.sh - the forge poller. Two triggers, each delivering a prompt into the
# repo's ONE live session (cc-<repo>, started by launch_session.sh: an interactive Claude
# session with Remote Control on, visible in claude.ai/code). The prompt is typed into
# the session's chat input, but only while the session is idle - a message typed during
# a turn is consumed mid-turn and derails the running work - so an event waits while
# the session is busy (claude's hooks flag that on the tmux session, see
# bin/cc-session-state.sh) and is retried on the next tick. A missing session is
# launched and the event delivered on a later tick.
#
#   1. @mentions  - watch Forgejo notifications for @mentions on issues.
#   2. reminders  - one-shot reminders a session set with `remind <repo> '<time>'
#                   '<prompt>'` (bin/remind.sh); delivered once the time has passed.
#
# Spawned by entrypoint.sh as a supervised background process when either
# ENABLE_MENTION_POLLER=1 or ENABLE_REMINDERS=1. Auth for mentions: the baked `forgejo`
# wrapper reads the token from ~/.config/forgejo-claude/token - no extra secrets.
# Reminders need no forge at all.
#
# Env:
#   ENABLE_MENTION_POLLER   "1" = deliver @mentions                    (default: 0)
#   ENABLE_REMINDERS        "1" = deliver reminders                    (default: 0)
#   MENTION_POLLER_INTERVAL main loop tick in seconds                 (default: 30)
#   MENTION_RATE_CAP        max deliveries + launches per hour, both triggers (default: 10)
#   REMINDERS_FILE          the reminders store          (default: ~/.claude/reminders.json)
#   FORGE_ORG               only act on mentions in this org (required for mentions)
#   FORGE_HOST              used to build human issue URLs   (e.g. https://git.example.com)
#   DRY_RUN                 "1" = log would-be actions; mention threads still marked read

set -euo pipefail

ENABLE_MENTION_POLLER="${ENABLE_MENTION_POLLER:-0}"
ENABLE_REMINDERS="${ENABLE_REMINDERS:-0}"
INTERVAL="${MENTION_POLLER_INTERVAL:-30}"
RATE_CAP="${MENTION_RATE_CAP:-10}"
REMINDERS_FILE="${REMINDERS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/reminders.json}"
DRY_RUN="${DRY_RUN:-0}"
FORGE_ORG="${FORGE_ORG:-}"
FORGE_HOST="${FORGE_HOST:-}"

log() { printf '%s [mention-poller] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }

if [ "$ENABLE_MENTION_POLLER" != "1" ] && [ "$ENABLE_REMINDERS" != "1" ]; then
  log "Neither ENABLE_MENTION_POLLER nor ENABLE_REMINDERS is 1 - nothing to do. Exiting."
  exit 1
fi

BOT_USER=""
if [ "$ENABLE_MENTION_POLLER" = "1" ]; then
  if [ -z "$FORGE_ORG" ]; then
    log "FORGE_ORG not set - required to scope mentions to your org. Exiting."
    exit 1
  fi
  # Resolve bot username once for the loop guard: skip notifications whose latest
  # comment was already written by us (prevents re-triggering on our own replies).
  BOT_USER="$(forgejo api GET /user 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || true)"
fi
log "Starting. mentions=${ENABLE_MENTION_POLLER} reminders=${ENABLE_REMINDERS} interval=${INTERVAL}s cap=${RATE_CAP}/hr dry_run=${DRY_RUN} bot=${BOT_USER:-unknown}"

# Rate-cap state (resets each calendar hour), shared by both triggers.
rate_hour=""
rate_count=0

# --- shared delivery helpers -------------------------------------------------

session_name() { printf 'cc-%s' "$1" | tr -c 'A-Za-z0-9_-' '-'; }

# Shared hourly cap. Returns 1 when the cap is reached.
rate_ok() {
  local cur_hour; cur_hour="$(date +%Y%m%d%H)"
  if [ "$cur_hour" != "$rate_hour" ]; then rate_hour="$cur_hour"; rate_count=0; fi
  [ "$rate_count" -lt "$RATE_CAP" ]
}

# pane_state <tmux-session>
# Reads the session's screen and prints one of:
#   noprompt  claude's input box (a ❯ at column 0; a dialog's ❯ is indented) is not shown
#   idle      the last transcript line above the input box is a finished-turn marker
#             ("✻ Cooked for 22s · done 6:11 PM") or "⎿  Interrupted · ..."
#   busy      the last transcript line is anything else (streaming text, a spinner)
#   fresh     nothing above the input box yet
# The input box is the LAST ❯ line, because earlier user messages in the transcript
# start with ❯ too. Separators, blank lines and the "Tip:" line are skipped.
pane_state() {
  tmux capture-pane -t "=$1:" -p 2>/dev/null | awk '
    /^❯/ { last = NR }
    { l[NR] = $0 }
    END {
      if (!last) { print "noprompt"; exit }
      for (i = last - 1; i > 0; i--) {
        s = l[i]
        if (s ~ /^[[:space:]]*$/ || s ~ /^─/ || s ~ /Tip:/) continue
        if (s ~ /· done / || s ~ /Interrupted/) print "idle"; else print "busy"
        exit
      }
      print "fresh"
    }'
}

# input_box_holds <tmux-session> <text>
# True while the input box (the LAST ❯ line, see pane_state) still shows the start of
# <text>. A submitted message moves up into the transcript and the box goes empty.
input_box_holds() {
  tmux capture-pane -t "=$1:" -p 2>/dev/null | HEAD="${2:0:40}" awk '
    /^❯/ { last = $0 }
    END { exit !(index(last, ENVIRON["HEAD"]) > 0) }'
}

# deliver <repo> <prompt>
# Types <prompt> into the repo's live session when it is idle. Starts the session when
# it is not live. Returns 1 when the session is not ready, busy or did not submit the
# text, so the caller keeps the event and retries next tick. A launch and a delivery
# attempt each count against the hourly cap, so a session that dies at once or never
# submits cannot be poked without limit.
# Busy comes from the tmux session option @cc_busy, which claude's own hooks set for
# the length of a turn (bin/cc-session-state.sh): the screen shows no busy marker while
# claude streams text, so it cannot be read from the pane. The screen is only the
# backstop for a stale flag: Stop does not fire after a user interrupt, so a flag that
# is still set while the screen shows a finished or interrupted turn is ignored.
# The text and the Enter are sent apart, and the Enter is checked. Sent together they
# can reach claude in one read, which its paste detection treats as one paste with the
# newline inside it, so the text sits in the input box unsubmitted (seen on a slow
# --continue session with a web client attached). An unsubmitted text is cleared with
# Ctrl-C (claude's "clear input" when the box is not empty) so the retry does not
# append a second copy.
deliver() {
  local repo="$1" prompt="$2" session state try
  session="$(session_name "$repo")"
  if ! tmux has-session -t "=$session" 2>/dev/null; then
    log "No live $session - launching"
    rate_count=$((rate_count + 1))
    launch_session.sh --approve "$repo" 2>&1 | while IFS= read -r line; do log "  $line"; done || true
    return 1
  fi
  state="$(pane_state "$session")"
  [ "$state" != "noprompt" ] && [ -n "$state" ] || { log "$session has no prompt yet"; return 1; }
  if [ "$(tmux show-options -qv -t "=$session:" @cc_busy 2>/dev/null)" = "1" ]; then
    if [ "$state" = "idle" ]; then
      log "$session busy flag is stale (screen shows the turn ended) - delivering"
    else
      log "$session is busy - event waits"; return 1
    fi
  fi
  rate_count=$((rate_count + 1))
  tmux send-keys -t "=$session:" -l -- "$prompt"
  sleep 0.5
  for try in 1 2 3; do
    tmux send-keys -t "=$session:" Enter
    sleep 1
    input_box_holds "$session" "$prompt" || return 0
    log "$session did not submit the text (Enter $try of 3)"
  done
  log "$session still holds the text after 3 Enters - clearing the input box, event waits"
  tmux send-keys -t "=$session:" C-c
  return 1
}

# --- trigger 1: @mentions ----------------------------------------------------

# Deliver a mention to the repo's session. The notification is marked read (the
# primary dedupe) only after a successful delivery, so a busy session retries.
dispatch() {
  local repo="$1" issue_num="$2" issue_url="$3" thread_id="$4"
  local prompt

  if ! rate_ok; then
    log "Rate cap ($RATE_CAP/hr) - skipping $repo#$issue_num"
    return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would deliver $repo#$issue_num ($issue_url) to $(session_name "$repo")"
    forgejo api PATCH "/notifications/threads/$thread_id" >/dev/null 2>&1 || true
    return
  fi

  prompt="You were @mentioned on a Forgejo issue. Read it with \`forgejo issue view $repo $issue_num\`, do the work if it is actionable and in scope, then reply with \`forgejo issue comment $repo $issue_num \"...\"\`. If you cannot or should not act, comment briefly why. Issue: $issue_url"
  if ! deliver "$repo" "$prompt"; then
    log "Mention $repo#$issue_num not delivered - retries next poll"
    return
  fi

  forgejo api PATCH "/notifications/threads/$thread_id" >/dev/null 2>&1 || true
  log "Delivered $repo#$issue_num to $(session_name "$repo") (thread $thread_id marked read)"
}

mention_scan() {
  local notifications thread_id org repo issue_num latest_cmt_url cmt_path latest_author
  notifications="$(forgejo api GET /notifications 2>/dev/null || true)"
  [ -n "$notifications" ] && [ "$notifications" != "[]" ] && [ "$notifications" != "null" ] || return 0
  while IFS=$'\t' read -r thread_id org repo issue_num latest_cmt_url; do
    [ -n "$thread_id" ] || continue

    # Only act on mentions within our configured org.
    if [ "$org" != "$FORGE_ORG" ]; then
      log "Skipping mention in foreign org $org/$repo#$issue_num"
      continue
    fi

    # Loop guard: if the latest comment was written by us, mark read and skip.
    if [ -n "$BOT_USER" ] && [ -n "$latest_cmt_url" ]; then
      cmt_path="$(printf '%s' "$latest_cmt_url" | sed 's|.*/api/v1||')"
      latest_author="$(forgejo api GET "$cmt_path" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('user',{}).get('login',''))" \
        2>/dev/null || true)"
      if [ "$latest_author" = "$BOT_USER" ]; then
        log "Skipping $repo#$issue_num - latest comment is our own reply (marking read)"
        forgejo api PATCH "/notifications/threads/$thread_id" >/dev/null 2>&1 || true
        continue
      fi
    fi

    log "Mention detected: $repo#$issue_num (thread $thread_id)"
    dispatch "$repo" "$issue_num" "${FORGE_HOST}/${FORGE_ORG}/${repo}/issues/${issue_num}" "$thread_id"
  done < <(printf '%s' "$notifications" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(0)
for n in data:
    if n.get('reason') != 'mention':
        continue
    subj = n.get('subject') or {}
    if subj.get('type') != 'Issue':
        continue
    url = subj.get('url', '')
    parts = url.rstrip('/').split('/')
    try:
        idx = parts.index('issues')
        print('\t'.join([
            str(n.get('id', '')),
            parts[idx - 2],  # org
            parts[idx - 1],  # repo
            parts[idx + 1],  # issue number
            subj.get('latest_comment_url', ''),
        ]))
    except (ValueError, IndexError):
        pass
" 2>/dev/null || true)
}

# --- trigger 2: reminders ----------------------------------------------------

# Each tick, deliver every reminder whose time has passed into its repo's session.
# A reminder is removed only after a good delivery, so a busy session or a failed
# launch retries next tick. `@tsv` escapes a backslash in a prompt as '\\'.
remind_scan() {
  local rows id repo prompt
  [ -s "$REMINDERS_FILE" ] || return 0
  rows="$(jq -r --argjson now "$(date +%s)" \
    '.[] | select(.at <= $now) | [.id, .repo, .prompt] | @tsv' "$REMINDERS_FILE" 2>/dev/null || true)"
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r id repo prompt; do
    [ -n "$id" ] || continue
    rate_ok || { log "Rate cap ($RATE_CAP/hr) - reminder $id waits"; continue; }
    if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN: would deliver reminder $id to $(session_name "$repo")"; continue; fi
    if ! deliver "$repo" "Reminder, set earlier by a session in $repo: $prompt"; then
      log "Reminder $id not delivered - retries next tick"
      continue
    fi
    remind cancel "$id" >/dev/null 2>&1 || log "WARNING: could not remove reminder $id - it fires again"
    log "Delivered reminder $id to $(session_name "$repo")"
  done <<< "$rows"
}

# --- main loop ---------------------------------------------------------------
while true; do
  if [ "$ENABLE_MENTION_POLLER" = "1" ]; then
    mention_scan
  fi
  if [ "$ENABLE_REMINDERS" = "1" ]; then
    remind_scan
  fi
  sleep "$INTERVAL"
done
