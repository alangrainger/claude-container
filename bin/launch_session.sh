#!/usr/bin/env bash
#
# launch_session.sh - the core session launcher and security boundary.
#
# Starts a `claude remote-control` session for an allowlisted name inside a detached
# tmux session named cc-<name>, in $WORKDIR/<name>, so it shows up in claude.ai/code.
# The always-on cc-control session calls this when you ask it (in plain English) to
# launch something; it is also runnable via `docker compose exec claude launch_session.sh`.
#
# Usage: launch_session.sh <name> [--approve] [--allow-dup]
#   <name>        short name; must be in the allowlist (or use --approve to add it)
#   --approve     add <name> to the allowlist, then launch
#   --allow-dup   if cc-<name> already exists, start a suffixed session instead of exiting
#
# A session launches in $WORKDIR/<name> (WORKDIR default /workspace), except that
# forge-org repos launch in $FORGE_WORKDIR/<name> (FORGE_WORKDIR defaults to $WORKDIR,
# so unset this is the same path); the allowlist is purely the set of approved NAMES,
# never a path. If that dir is missing and GIT_BASE is set, it is cloned from
# $GIT_BASE/<name>.git (with GIT_USER:GIT_TOKEN basic auth if GIT_TOKEN is set) - any
# git host works, nothing forge-specific is baked in. With GIT_BASE unset, the dir must
# already exist (e.g. mounted).
#
# An allowlisted dir is auto-trusted on first launch (the allowlist is the trust
# boundary), so the headless trust dialog never needs answering by hand.
#
# Config via env (all optional): WORKDIR, FORGE_WORKDIR, GIT_BASE, GIT_TOKEN, GIT_USER
# (default git), WEB_NAME_FORMAT (default "{repo}"), PERMISSION_MODE (default acceptEdits),
# CC_LAUNCHER_CONFIG (allowlist path).
#
# Exit codes: 0 ok / already-live, 2 bad usage, 3 rejected (not allowlisted / invalid
# name / missing dir), 5 workspace not trusted and could not be auto-trusted.

set -euo pipefail

CONFIG="${CC_LAUNCHER_CONFIG:-$HOME/.config/cc-launcher/repos.conf}"
CFGJSON="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"   # claude's config (trust lives here)
WORKDIR="${WORKDIR:-/workspace}"          # where sessions launch: $WORKDIR/<name>
# Auto-clone base. Opinionated default: the Forgejo org ($FORGE_HOST/$FORGE_ORG) when
# both are set; otherwise unset (the dir must already exist). GIT_BASE overrides.
_forge_base=""
[ -n "${FORGE_HOST:-}" ] && [ -n "${FORGE_ORG:-}" ] && _forge_base="${FORGE_HOST%/}/$FORGE_ORG"
GIT_BASE="${GIT_BASE:-$_forge_base}"
GIT_TOKEN="${GIT_TOKEN:-${FORGE_TOKEN:-}}"  # falls back to the Forgejo token
GIT_USER="${GIT_USER:-git}"               # basic-auth username paired with GIT_TOKEN
SPAWN_MODE="session"                      # classic single-session: one tmux = one chat
PERMISSION_MODE="${PERMISSION_MODE:-acceptEdits}"
FORGE_WORKDIR="${FORGE_WORKDIR:-$WORKDIR}"   # where forge-org repos launch; default = $WORKDIR (no-op)
# Display name in claude.ai/code; {repo} is replaced with the name. The tmux session
# stays cc-<name> regardless (tooling keys off that). Default: "<WEB_NAME_PREFIX> {repo}"
# (same prefix cc-control uses), or just "{repo}" with no prefix; WEB_NAME_FORMAT overrides.
# (Set in steps - "${x:-{repo}}" mis-parses the nested brace and leaves a stray }.)
WEB_NAME_PREFIX="${WEB_NAME_PREFIX:-}"
WEB_NAME_FORMAT="${WEB_NAME_FORMAT:-}"
if [ -z "$WEB_NAME_FORMAT" ]; then
  if [ -n "$WEB_NAME_PREFIX" ]; then WEB_NAME_FORMAT="$WEB_NAME_PREFIX {repo}"; else WEB_NAME_FORMAT='{repo}'; fi
fi

die()  { printf 'launch_session: %s\n' "$1" >&2; exit "${2:-1}"; }
note() { printf '%s\n' "$1"; }

usage() { sed -n '5,18p' "$0" | sed 's/^# \{0,1\}//'; }

# remote-control refuses an untrusted workspace and cannot answer the trust dialog
# headlessly. Trust is recorded once per dir in ~/.claude.json, via jq (the image ships
# jq, not python3). If jq is somehow absent, assume trusted and let claude report it.
workspace_trusted() {
  local f="$CFGJSON"
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$f" ] || return 1
  jq -e --arg d "$1" '(.projects[$d].hasTrustDialogAccepted // false) == true' "$f" >/dev/null 2>&1
}

# Auto-trust an allowlisted dir (the allowlist IS the trust boundary). Atomic write
# (temp + rename); jq path-assignment auto-creates the intermediate objects. Non-zero
# only if it cannot write.
trust_workspace() {
  local f="$CFGJSON" tmp
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$f" ] || printf '{}\n' > "$f"
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  if jq --arg d "$1" '.projects[$d].hasTrustDialogAccepted = true' "$f" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Auto-clone <name> from $GIT_BASE if the dir is missing and GIT_BASE is set. Generic:
# $GIT_BASE/<name>.git, optionally with GIT_USER:GIT_TOKEN HTTP basic auth (the
# git-over-https standard - works for GitHub, GitLab, Forgejo, ...). No host baked in.
maybe_autoclone() {
  local name="$1" path="$2"
  [ -n "$GIT_BASE" ] || return 0
  local url="${GIT_BASE%/}/$name.git"
  note "Auto-cloning $url ..."
  local -a auth=()
  if [ -n "$GIT_TOKEN" ]; then
    local b64; b64="$(printf '%s' "$GIT_USER:$GIT_TOKEN" | base64 | tr -d '\n')"
    auth=(-c "http.extraHeader=Authorization: Basic $b64")
  fi
  if git "${auth[@]}" clone --quiet "$url" "$path" >/dev/null 2>&1; then
    note "Cloned into $path"
  else
    note "auto-clone of '$name' failed - check GIT_BASE/GIT_TOKEN and that the repo exists"
  fi
}

# Path a name launches in.
#  - Forge-org repos (the launcher's GIT_BASE is the forge org) launch in
#    $FORGE_WORKDIR/<name>. FORGE_WORKDIR defaults to $WORKDIR, so unless an
#    operator points it elsewhere this is byte-for-byte the old behaviour - the
#    public default is unchanged. Pointing FORGE_WORKDIR at a canonical clones
#    dir (e.g. one a SessionStart hook also manages) keeps org repos in one place
#    instead of a duplicate under $WORKDIR.
#  - An existing checkout wins over a fresh clone: a canonical clone at
#    $FORGE_WORKDIR/<name> is used if present; failing that a pre-existing
#    $WORKDIR/<name> (a mount, or a legacy clone) is respected so it is never
#    orphaned. Only a genuinely fresh forge-org repo clones to $FORGE_WORKDIR.
#  - Everything else launches in $WORKDIR/<name>, exactly as before.
repo_path_for() {
  local name="$1"
  if [ -n "${FORGE_HOST:-}" ] && [ -n "${FORGE_ORG:-}" ] && \
     [ "${GIT_BASE%/}" = "${FORGE_HOST%/}/${FORGE_ORG}" ]; then
    if [ -d "${FORGE_WORKDIR%/}/$name/.git" ]; then
      printf '%s/%s' "${FORGE_WORKDIR%/}" "$name"
    elif [ -d "${WORKDIR%/}/$name" ]; then
      printf '%s/%s' "${WORKDIR%/}" "$name"
    else
      printf '%s/%s' "${FORGE_WORKDIR%/}" "$name"
    fi
  else
    printf '%s/%s' "${WORKDIR%/}" "$name"
  fi
}

# Claude Code pins a working dir's web session id in
# ~/.claude/projects/<dir-slug>/bridge-pointer.json and REUSES it on the next launch in
# that dir. After a kill the process is gone but the file still points at the dead
# session, so a relaunch hands back a dead URL. If the recorded pid is no longer alive,
# archive the file so claude mints a fresh id. A live session keeps its pointer.
reset_stale_bridge_pointer() {
  local dir="$1" slug bp pid
  slug="$(printf '%s' "$dir" | sed 's#[^A-Za-z0-9]#-#g')"
  bp="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug/bridge-pointer.json"
  [ -f "$bp" ] || return 0
  pid="$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$bp" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null && return 0
  if mv "$bp" "$bp.stale" 2>/dev/null; then
    note "Reset stale bridge pointer (pid $pid gone) - a fresh web session id will be minted"
  fi
}

# --- parse args ------------------------------------------------------------
repo=""
allow_dup=0
approve=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dup) allow_dup=1 ;;
    --approve)   approve=1 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "unknown option: $1" 2 ;;
    *)           [ -z "$repo" ] || die "unexpected extra argument: $1" 2; repo="$1" ;;
  esac
  shift
done
[ -n "$repo" ] || die "usage: launch_session.sh <name> [--approve] [--allow-dup]" 2

# --- validate the name (blocks path traversal) -----------------------------
case "$repo" in
  *[!A-Za-z0-9._-]*) die "rejected: name '$repo' has illegal characters" 3 ;;
  ''|.|..)           die "rejected: name '$repo' is not allowed" 3 ;;
esac

# --- approve on request: add <name> to the allowlist, then continue ---------
if [ "$approve" -eq 1 ]; then
  [ -f "$CONFIG" ] || { mkdir -p "$(dirname "$CONFIG")"; : > "$CONFIG"; }
  if grep -qE "^[[:space:]]*$repo([[:space:]]|=|$)" "$CONFIG" 2>/dev/null; then
    note "'$repo' is already in the allowlist."
  else
    printf '%s\n' "$repo" >> "$CONFIG"
    note "Approved '$repo' (will launch in $(repo_path_for "$repo"))"
  fi
fi

# --- check the allowlist (membership only) ---------------------------------
# The allowlist is just the set of approved NAMES. The working dir is computed by
# repo_path_for() (below), never a path from the file.
[ -f "$CONFIG" ] || die "allowlist not found: $CONFIG (create it, or use --approve <name>)" 3

approved=0
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"                       # strip comments
  case "$line" in *[![:space:]]*) ;; *) continue ;; esac  # skip blank
  name="${line%%=*}"                       # name = before '=' (legacy path ignored)
  name="$(printf '%s' "$name" | xargs)"    # trim whitespace
  if [ "$name" = "$repo" ]; then approved=1; break; fi
done < "$CONFIG"

[ "$approved" -eq 1 ] || die "rejected: '$repo' is not in the allowlist.
  Allowlist:  $CONFIG
  To allow it, add a line with just its name:
      $repo
  then re-run.  Or do it in one step:  launch_session.sh --approve $repo" 3

# Sessions launch in $WORKDIR/<name>; forge-org repos may launch in $FORGE_WORKDIR/<name>.
repo_path="$(repo_path_for "$repo")"
[ -d "$repo_path" ] || maybe_autoclone "$repo" "$repo_path"
[ -d "$repo_path" ] || die "rejected: '$repo' has no dir at $repo_path - mount it there, or set GIT_BASE so it can be cloned" 3

# --- workspace trust: auto-grant for allowlisted dirs ----------------------
if ! workspace_trusted "$repo_path"; then
  if trust_workspace "$repo_path"; then
    note "Trusted workspace $repo_path (first launch, via the allowlist)"
  else
    die "rejected: workspace '$repo_path' is not trusted and could not be auto-trusted (needs jq and a writable ~/.claude.json)." 5
  fi
fi

# --- session naming --------------------------------------------------------
tmux_session="$(printf 'cc-%s' "$repo" | tr -c 'A-Za-z0-9_-' '-')"  # tmux-safe
web_name="${WEB_NAME_FORMAT//\{repo\}/$repo}"

session_exists() { tmux has-session -t "=$1" 2>/dev/null; }

if session_exists "$tmux_session"; then
  if [ "$allow_dup" -eq 0 ]; then
    note "Already live: $tmux_session (use --allow-dup to start another). Open https://claude.ai/code"
    exit 0
  fi
  n=2
  while session_exists "${tmux_session}-${n}"; do n=$((n+1)); done
  tmux_session="${tmux_session}-${n}"
  web_name="$web_name #$n"
fi

# Committed to launching now, so clear a stale pointer first.
reset_stale_bridge_pointer "$repo_path"

# --- launch ----------------------------------------------------------------
# API keys are not supported for Remote Control; make sure none leaks in.
unset ANTHROPIC_API_KEY

cmd="exec env -u ANTHROPIC_API_KEY claude remote-control"
cmd="$cmd --spawn $(printf '%q' "$SPAWN_MODE")"
cmd="$cmd --name $(printf '%q' "$web_name")"
cmd="$cmd --permission-mode $(printf '%q' "$PERMISSION_MODE")"

tmux new-session -d -s "$tmux_session" -c "$repo_path" "$cmd"

sleep 1
if session_exists "$tmux_session"; then
  note "Launched $tmux_session  ($repo_path)"
  note "Open https://claude.ai/code and attach to \"$web_name\"."
else
  die "session '$tmux_session' exited immediately - check 'claude' login (Pro/Max), workspace trust, and that ANTHROPIC_API_KEY is unset" 1
fi
