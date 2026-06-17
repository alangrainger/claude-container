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
RUN apk add --no-cache bash tmux git jq curl ripgrep ca-certificates python3 py3-pip \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

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
 && chown -R node:node /home/node /workspace

# Image-versioned scripts (live outside the volume, so a rebuild updates them).
# `forgejo` is the opinionated forge wrapper (Forgejo; Gitea likely works). It reads
# FORGE_HOST/FORGE_ORG/FORGE_TOKEN at runtime - nothing host-specific is baked in. A
# personalisation hook can still shadow it via ~/.local/bin (earlier on PATH).
COPY entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY scripts/first-setup.sh /usr/local/bin/first-setup.sh
COPY bin/launch_session.sh  /usr/local/bin/launch_session.sh
COPY bin/forgejo            /usr/local/bin/forgejo
# Instructions the control session reads (entrypoint installs it as CONTROL_DIR/CLAUDE.md
# so the agent knows it can launch other sessions via launch_session.sh).
COPY control/CLAUDE.md      /usr/local/share/control-CLAUDE.md
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/first-setup.sh \
             /usr/local/bin/launch_session.sh /usr/local/bin/forgejo

ENV HOME=/home/node \
    PATH=/home/node/.local/bin:/usr/local/bin:/usr/bin:/bin \
    CLAUDE_CONFIG_DIR=/home/node/.claude
USER node
WORKDIR /home/node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
