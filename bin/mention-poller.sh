#!/usr/bin/env bash
# mention-poller.sh — watch Forgejo notifications for @mentions and dispatch
# them to the appropriate live cc-<repo> Claude session (or spawn one first).
#
# Spawned by entrypoint.sh as a supervised background process when
# ENABLE_MENTION_POLLER=1. Auth: the baked `forgejo` wrapper reads the token
# from ~/.config/forgejo-claude/token - no extra secrets needed.
#
# Env:
#   ENABLE_MENTION_POLLER   must be "1" (checked by entrypoint.sh before spawning)
#   MENTION_POLLER_INTERVAL poll interval in seconds         (default: 30)
#   MENTION_RATE_CAP        max dispatches per hour          (default: 10)
#   FORGE_ORG               only act on mentions in this org (required)
#   FORGE_HOST              used to build human issue URLs   (e.g. https://git.example.com)
#   DRY_RUN                 "1" = log would-be actions; threads still marked read

set -euo pipefail

INTERVAL="${MENTION_POLLER_INTERVAL:-30}"
RATE_CAP="${MENTION_RATE_CAP:-10}"
DRY_RUN="${DRY_RUN:-0}"
FORGE_ORG="${FORGE_ORG:-}"
FORGE_HOST="${FORGE_HOST:-}"

log() { printf '[mention-poller] %s\n' "$*"; }

if [ -z "$FORGE_ORG" ]; then
  log "FORGE_ORG not set - required to filter mentions to your org. Exiting."
  exit 1
fi

# Resolve bot username once for the loop guard: skip notifications whose latest
# comment was already written by us (prevents re-triggering on our own replies).
BOT_USER="$(forgejo api GET /user 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || true)"
log "Starting. interval=${INTERVAL}s cap=${RATE_CAP}/hr dry_run=${DRY_RUN} bot=${BOT_USER:-unknown}"

# Rate-cap state (resets each calendar hour).
rate_hour=""
rate_count=0

# Inject a mention into an existing or freshly-spawned session.
dispatch() {
  local repo="$1" issue_num="$2" issue_url="$3" thread_id="$4"
  local cur_hour session prompt i ready

  cur_hour="$(date +%Y%m%d%H)"
  if [ "$cur_hour" != "$rate_hour" ]; then rate_hour="$cur_hour"; rate_count=0; fi
  if [ "$rate_count" -ge "$RATE_CAP" ]; then
    log "Rate cap ($RATE_CAP/hr) - skipping $repo#$issue_num"
    return
  fi

  # Session name uses the same transform as launch_session.sh.
  session="$(printf 'cc-%s' "$repo" | tr -c 'A-Za-z0-9_-' '-')"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would inject into $session for $repo#$issue_num ($issue_url)"
    forgejo api PATCH "/notifications/threads/$thread_id" 2>/dev/null || true
    return
  fi

  # Reuse a live session or spawn one via launch_session.sh (which handles
  # auto-clone, auto-trust, and bridge-pointer reset automatically).
  if ! tmux has-session -t "=$session" 2>/dev/null; then
    log "No live $session - spawning via launch_session.sh --approve $repo"
    launch_session.sh --approve "$repo" 2>&1 | while IFS= read -r line; do log "  $line"; done || true
    # Poll until the Claude Code remote-control pane shows a prompt (bounded).
    ready=0
    for i in $(seq 1 30); do
      sleep 2
      tmux has-session -t "=$session" 2>/dev/null || continue
      tmux capture-pane -t "=$session" -p 2>/dev/null | grep -qE '[>?]' && { ready=1; break; }
    done
    if [ "$ready" -eq 0 ]; then
      log "Timed out waiting for $session to be ready - skipping inject for $repo#$issue_num"
      return
    fi
  fi

  prompt="You were @mentioned on a Forgejo issue. Read it with \`forgejo issue view $repo $issue_num\`, do the work if it is actionable and in scope, then reply with \`forgejo issue comment $repo $issue_num \"...\"\`. If you cannot or should not act, comment briefly why. Issue: $issue_url"
  log "Injecting mention into $session ($repo#$issue_num)"
  tmux send-keys -t "=$session" -l -- "$prompt"
  tmux send-keys -t "=$session" Enter
  rate_count=$((rate_count + 1))

  # Mark read - this is the primary dedupe; the next tick won't re-see this thread.
  forgejo api PATCH "/notifications/threads/$thread_id" 2>/dev/null || true
  log "Dispatched $repo#$issue_num (thread $thread_id marked read)"
}

while true; do
  notifications="$(forgejo api GET /notifications 2>/dev/null || true)"
  if [ -n "$notifications" ] && [ "$notifications" != "[]" ] && [ "$notifications" != "null" ]; then
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
  fi
  sleep "$INTERVAL"
done
