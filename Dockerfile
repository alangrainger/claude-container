# claude-container - single-container sandbox for the Claude remote-control workflow.
# Engine: Docker via OrbStack on the Mac; kept OCI-standard so it also
# builds/runs under Podman on the Linux servers.
#
# Alpine base for a small image. NOTE: Alpine is musl, not glibc - claude-code bundles
# native bits (ripgrep), so musl compatibility is verified at build/run, not assumed.
FROM node:22-alpine

# claude-code version. Defaults to `latest` so a fresh build gets the current release -
# operators want new features/fixes, and it's a fast-moving research preview. Pin a
# specific version for reproducible builds: --build-arg CLAUDE_CODE_VERSION=2.1.179.
# Note: Docker caches the npm layer, so `docker compose build --no-cache` (or --pull) is
# what actually re-pulls `latest`. Requires Claude Code >= 2.1.52.
ARG CLAUDE_CODE_VERSION=latest

# Runtime tooling, kept lean. System plumbing: bash (scripts/launcher use bashisms -
# Alpine's default shell is busybox ash), tmux (one session per conversation), git
# (clone/auto-clone), jq (launcher trust handling - the plumbing stays independent of
# the agent's python), curl (HTTP/API calls - commonly needed by setup hooks and the
# agent), ripgrep (claude-code uses a system `rg` and bundles none; this is the
# musl-native build), ca-certificates. kill -0 liveness uses the bash builtin, no procps.
# Agent toolbox: python3 + pip - the in-container agent reaches for python constantly
# for small scripts/data work, so it ships in the image (a dev env without it is
# crippling). Note: Alpine enforces PEP 668, so `pip install` wants a venv or
# --break-system-packages; the agent can apk-add build deps at runtime for C wheels.
# github-cli (`gh`) - browse GitHub from inside the container. Needs a dev-supplied
# GH_TOKEN to be useful (see .env.example); read-only with a no-scope classic PAT.
# docker-cli + docker-cli-compose: Docker CLI and the Compose v2 plugin. Connects to
# the host daemon via a mounted socket (DooD) - no daemon runs inside the container.
# DOCKER_CONFIG points at the persisted ~/.config volume so `docker login` / contexts
# survive image rebuilds. See compose.yaml for how to mount the host socket.
# sqlite: the `sqlite3` CLI for inspecting SQLite databases (e.g. app state in tests).
# openssl: key/cert operations and hashing in agent scripts and test harnesses.
# chromium + fonts: a headless browser for the agent (page fetches, screenshots, PDF,
# Puppeteer/Playwright). Alpine's build is musl-native and exists for both arches -
# Puppeteer's own glibc download would not run here, hence PUPPETEER_* below. The flags
# it needs to run under this container's hardening live in /etc/chromium (see below).
# font-noto covers Latin/Greek/Cyrillic text; add font-noto-cjk for CJK if you need it.
RUN apk add --no-cache bash tmux git jq curl ripgrep ca-certificates python3 py3-pip github-cli \
    docker-cli docker-cli-compose sqlite openssl \
    chromium font-noto font-noto-emoji \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# Chromium flags, sourced by Alpine's /usr/bin/chromium{,-browser} launcher on every start
# (also the path Puppeteer/Playwright use via PUPPETEER_EXECUTABLE_PATH). Caller flags come
# after these, so tools that pass their own --user-data-dir etc. still win.
#   --no-sandbox            Chromium's own sandbox needs setuid or user namespaces; both
#                           are blocked by cap_drop ALL + no-new-privileges. The container
#                           (non-root, read-only rootfs) is the sandbox instead.
#   --headless              no display in the container.
#   --disable-gpu           no GPU; avoids GL init noise.
#   --disable-dev-shm-usage /dev/shm is 64 MB by default; use /tmp for shared memory.
#   --user-data-dir=<tmp>   a fresh profile per launch under /tmp (tmpfs): keeps the
#                           read-only rootfs / ~/.claude volume clean and lets concurrent
#                           sessions each run their own instance.
#   XDG_CONFIG_HOME=/tmp/.. Chromium insists on creating its crash-report database under
#                           $XDG_CONFIG_HOME/chromium regardless of --user-data-dir, and
#                           aborts (SIGTRAP) if it can't. Pointing it at /tmp keeps that
#                           off the persisted ~/.config volume. Scoped to Chromium only:
#                           the conf is sourced by the launcher, not the user's shell.
#   XDG_CACHE_HOME=/tmp/..  fontconfig wants a writable cache dir or it complains on
#                           every launch (~/.cache is on the read-only rootfs).
RUN mkdir -p /etc/chromium \
 && printf '%s\n' \
      'export XDG_CONFIG_HOME=/tmp/chromium-config XDG_CACHE_HOME=/tmp/chromium-cache' \
      'CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox --headless --disable-gpu --disable-dev-shm-usage --user-data-dir=$(mktemp -d /tmp/chromium.XXXXXX)"' \
      > /etc/chromium/claude-container.conf

# Non-root user (isolation). The node base image already ships a
# UID-1000 `node` user; reuse it. Only ~/.claude is the named volume (kept small - no
# ~/.npm/.cache bloat). Two things make that single dir hold everything that must persist:
#   - CLAUDE_CONFIG_DIR=~/.claude (set below) makes claude write its config there -
#     .claude.json (account/org info), credentials, projects, sessions - instead of the
#     default $HOME/.claude.json which sits OUTSIDE ~/.claude and would be lost on rebuild.
#   - ~/.config and ~/.local are symlinked INTO ~/.claude, so a personalisation hook's
#     CLI on PATH (~/.local/bin) and config (~/.config) persist there too.
# Pre-create the dirs owned by node so the fresh volume seeds with the right ownership
# (an unseeded named-volume mountpoint is otherwise root-owned and unwritable).
RUN mkdir -p /home/node/.claude/.local/bin /home/node/.claude/.config /workspace \
 && ln -s .claude/.local  /home/node/.local \
 && ln -s .claude/.config /home/node/.config \
 && printf '{"permissions":{"allow":["Bash(docker *)","Bash(docker compose *)"]}}\n' \
    > /home/node/.claude/settings.json \
 && chown -R node:node /home/node /workspace

# Image-versioned scripts (live outside the volume, so a rebuild updates them).
# `forgejo` is the opinionated forge wrapper (Forgejo; Gitea likely works). It reads
# FORGE_HOST/FORGE_ORG/FORGE_TOKEN at runtime - nothing host-specific is baked in. A
# personalisation hook can still shadow it via ~/.local/bin (earlier on PATH).
COPY entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY scripts/first-setup.sh /usr/local/bin/first-setup.sh
COPY scripts/reauth.sh /usr/local/bin/reauth.sh
COPY bin/launch_session.sh  /usr/local/bin/launch_session.sh
COPY bin/forgejo             /usr/local/bin/forgejo
COPY bin/mention-poller.sh  /usr/local/bin/mention-poller.sh
# Instructions the control session reads (entrypoint installs it as CONTROL_DIR/CLAUDE.md
# so the agent knows it can launch other sessions via launch_session.sh).
COPY control/CLAUDE.md      /usr/local/share/control-CLAUDE.md
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/first-setup.sh \
             /usr/local/bin/reauth.sh \
             /usr/local/bin/launch_session.sh /usr/local/bin/forgejo \
             /usr/local/bin/mention-poller.sh

ENV HOME=/home/node \
    PATH=/home/node/.local/bin:/usr/local/bin:/usr/bin:/bin \
    CLAUDE_CONFIG_DIR=/home/node/.claude \
    DOCKER_CONFIG=/home/node/.config/docker \
    CHROME_BIN=/usr/bin/chromium-browser \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
    PUPPETEER_SKIP_DOWNLOAD=1
USER node
WORKDIR /home/node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
