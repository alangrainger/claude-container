#!/usr/bin/env bash
# mention-poller.sh - the forge poller. Two triggers, both dispatching a prompt
# into the right live cc-<repo> Claude session (spawning it first if needed):
#
#   1. @mentions  - watch Forgejo notifications for @mentions on issues.
#   2. due dates  - once an hour, scan the org for open issues whose due date has
#                   passed and wake a session on each one (then clear the date and
#                   leave an audit comment). A session asks for a wake-up with
#                   `forgejo issue due <repo> <n> <YYYY-MM-DD>`.
#
# Spawned by entrypoint.sh as a supervised background process when either
# ENABLE_MENTION_POLLER=1 or ENABLE_DUE_WAKEUP=1. Auth: the baked `forgejo`
# wrapper reads the token from ~/.config/forgejo-claude/token - no extra secrets.
#
# Env:
#   ENABLE_MENTION_POLLER   "1" = dispatch @mentions                  (default: 0)
#   ENABLE_DUE_WAKEUP       "1" = wake sessions on passed due dates   (default: 0)
#   MENTION_POLLER_INTERVAL main loop tick in seconds                 (default: 30)
#   DUE_SCAN_INTERVAL       seconds between due-date scans           (default: 3600)
#   MENTION_RATE_CAP        max dispatches per hour, both triggers    (default: 10)
#   FORGE_ORG               only act on issues in this org (required)
#   FORGE_HOST              used to build human issue URLs   (e.g. https://git.example.com)
#   DRY_RUN                 "1" = log would-be actions; mention threads still marked read

set -euo pipefail

ENABLE_MENTION_POLLER="${ENABLE_MENTION_POLLER:-0}"
ENABLE_DUE_WAKEUP="${ENABLE_DUE_WAKEUP:-0}"
INTERVAL="${MENTION_POLLER_INTERVAL:-30}"
DUE_SCAN_INTERVAL="${DUE_SCAN_INTERVAL:-3600}"
RATE_CAP="${MENTION_RATE_CAP:-10}"
DRY_RUN="${DRY_RUN:-0}"
FORGE_ORG="${FORGE_ORG:-}"
FORGE_HOST="${FORGE_HOST:-}"

log() { printf '%s [mention-poller] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }

if [ -z "$FORGE_ORG" ]; then
  log "FORGE_ORG not set - required to scope the poller to your org. Exiting."
  exit 1
fi
if [ "$ENABLE_MENTION_POLLER" != "1" ] && [ "$ENABLE_DUE_WAKEUP" != "1" ]; then
  log "Neither ENABLE_MENTION_POLLER nor ENABLE_DUE_WAKEUP is 1 - nothing to do. Exiting."
  exit 1
fi

# Resolve bot username once for the loop guard: skip notifications whose latest
# comment was already written by us (prevents re-triggering on our own replies).
BOT_USER="$(forgejo api GET /user 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || true)"
log "Starting. mentions=${ENABLE_MENTION_POLLER} due_wakeup=${ENABLE_DUE_WAKEUP} interval=${INTERVAL}s due_scan=${DUE_SCAN_INTERVAL}s cap=${RATE_CAP}/hr dry_run=${DRY_RUN} bot=${BOT_USER:-unknown}"

# Rate-cap state (resets each calendar hour), shared by both triggers.
rate_hour=""
rate_count=0

# --- shared dispatch helpers -------------------------------------------------

# Session name uses the same transform as launch_session.sh.
session_name() { printf 'cc-%s' "$1" | tr -c 'A-Za-z0-9_-' '-'; }

# Shared hourly cap. Returns 1 when the cap is reached.
rate_ok() {
  local cur_hour; cur_hour="$(date +%Y%m%d%H)"
  if [ "$cur_hour" != "$rate_hour" ]; then rate_hour="$cur_hour"; rate_count=0; fi
  [ "$rate_count" -lt "$RATE_CAP" ]
}

# Make cc-<repo> live and at its prompt. Reuses a live session or spawns one via
# launch_session.sh (which handles auto-clone, auto-trust and bridge-pointer
# reset), then polls until the remote-control pane shows a prompt. Returns 1 on
# timeout.
ensure_session() {
  local repo="$1" session="$2" i
  tmux has-session -t "=$session" 2>/dev/null && return 0
  log "No live $session - spawning via launch_session.sh --approve $repo"
  launch_session.sh --approve "$repo" 2>&1 | while IFS= read -r line; do log "  $line"; done || true
  for i in $(seq 1 30); do
    sleep 2
    tmux has-session -t "=$session" 2>/dev/null || continue
    tmux capture-pane -t "=$session" -p 2>/dev/null | grep -qE '[>?]' && return 0
  done
  return 1
}

# Type a prompt into a session and submit it.
inject() {
  tmux send-keys -t "=$1" -l -- "$2"
  tmux send-keys -t "=$1" Enter
}

# --- trigger 1: @mentions ----------------------------------------------------

# Inject a mention into an existing or freshly-spawned session.
dispatch() {
  local repo="$1" issue_num="$2" issue_url="$3" thread_id="$4"
  local session prompt

  if ! rate_ok; then
    log "Rate cap ($RATE_CAP/hr) - skipping $repo#$issue_num"
    return
  fi
  session="$(session_name "$repo")"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would inject into $session for $repo#$issue_num ($issue_url)"
    forgejo api PATCH "/notifications/threads/$thread_id" 2>/dev/null || true
    return
  fi

  if ! ensure_session "$repo" "$session"; then
    log "Timed out waiting for $session to be ready - skipping inject for $repo#$issue_num"
    return
  fi

  prompt="You were @mentioned on a Forgejo issue. Read it with \`forgejo issue view $repo $issue_num\`, do the work if it is actionable and in scope, then reply with \`forgejo issue comment $repo $issue_num \"...\"\`. If you cannot or should not act, comment briefly why. Issue: $issue_url"
  log "Injecting mention into $session ($repo#$issue_num)"
  inject "$session" "$prompt"
  rate_count=$((rate_count + 1))

  # Mark read - this is the primary dedupe; the next tick won't re-see this thread.
  forgejo api PATCH "/notifications/threads/$thread_id" 2>/dev/null || true
  log "Dispatched $repo#$issue_num (thread $thread_id marked read)"
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
        forgejo api PATCH "/notifications/threads/$thread_id" 2>/dev/null || true
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

# --- trigger 2: due-date wake-ups --------------------------------------------

# One org-wide search, paged by 50, then one dispatch per open issue whose due
# date has passed. The date is cleared and the audit comment posted only AFTER a
# successful inject: a cleared date with a failed dispatch would lose the
# wake-up, whereas a duplicate prompt after a crash only costs tokens.
# Due dates carry a UTC offset (e.g. 2026-11-06T23:59:59+13:00) that jq's
# fromdate can't parse, so the comparison is done in python3.
due_scan() {
  local page=1 rows repo n url session prompt count
  while :; do
    rows="$(forgejo api GET "/repos/issues/search?owner=$FORGE_ORG&state=open&type=issues&limit=50&page=$page" 2>/dev/null \
      | python3 -c '
import sys, json
from datetime import datetime, timezone
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(0)
now = datetime.now(timezone.utc)
for i in data:
    d = i.get("due_date")
    if d and datetime.fromisoformat(d) < now:
        print("\t".join([i["repository"]["name"], str(i["number"]), i.get("html_url", "")]))
print("__count__\t%d" % len(data))
' 2>/dev/null || true)"
    count="$(printf '%s\n' "$rows" | awk -F'\t' '$1=="__count__"{print $2}')"
    [ -n "$count" ] || { log "Due scan: API call failed on page $page"; return; }
    while IFS=$'\t' read -r repo n url; do
      [ -n "$repo" ] && [ "$repo" != "__count__" ] || continue
      rate_ok || { log "Rate cap ($RATE_CAP/hr) - skipping wake-up $repo#$n"; continue; }
      session="$(session_name "$repo")"
      if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN: would wake $session for $repo#$n ($url)"; continue; fi
      if ! ensure_session "$repo" "$session"; then
        log "Timed out waiting for $session - wake-up for $repo#$n retries next scan"
        continue
      fi
      prompt="Wake-up: the due date on issue $repo#$n has passed. Read it with \`forgejo issue view $repo $n\` and do its steps. When done, report with \`forgejo issue comment $repo $n \"...\"\`. If the work needs another wake-up, set one with \`forgejo issue due $repo $n <YYYY-MM-DD>\`. Issue: $url"
      inject "$session" "$prompt"
      rate_count=$((rate_count + 1))
      forgejo api PATCH "/repos/$FORGE_ORG/$repo/issues/$n" '{"unset_due_date":true}' >/dev/null 2>&1 \
        || log "WARNING: could not clear the due date on $repo#$n - it fires again next scan"
      forgejo api POST "/repos/$FORGE_ORG/$repo/issues/$n/comments" \
        '{"body":"Wake-up fired. The due date passed and a session started on this issue."}' >/dev/null 2>&1 || true
      log "Woke $session for $repo#$n (due date cleared)"
    done <<< "$rows"
    [ "$count" -ge 50 ] || break
    page=$((page + 1))
  done
}

# --- main loop ---------------------------------------------------------------
# The first due scan runs at start; last_due_scan lives in memory only.
last_due_scan=0
while true; do
  if [ "$ENABLE_MENTION_POLLER" = "1" ]; then
    mention_scan
  fi
  if [ "$ENABLE_DUE_WAKEUP" = "1" ]; then
    now="$(date +%s)"
    if [ $((now - last_due_scan)) -ge "$DUE_SCAN_INTERVAL" ]; then
      due_scan
      last_due_scan="$now"
    fi
  fi
  sleep "$INTERVAL"
done
