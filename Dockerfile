# MiroTalk P2P — self-hosted peer-to-peer WebRTC video conferencing.
#
# Architecture: a tiny Node.js signaling server (Express + socket.io).
# Browsers use the signaling to negotiate SDP + ICE, then open
# RTCPeerConnections directly to each other. The server never touches
# media. That's why there's only one TCP port published and no media
# UDP port range needed.
#
# We build from the upstream git repo pinned to a specific commit
# rather than using the published `mirotalk/p2p:latest` image. Two
# reasons: (a) reproducibility and (b) the upstream image ships with
# a committed self-signed TLS cert that httpolyglot reads at boot --
# we include that same cert in our image via the git clone.

# Pin upstream to a known-good commit (2026-04-22). Bump as needed.
ARG MIROTALK_REF=627e9299c15f302236864f9cdf020d1df298ebc8

# ------------------------------------------------------------ builder
# Clone + install npm deps in a throwaway stage so the final image
# doesn't include git or build metadata.
FROM node:22-alpine AS builder

ARG MIROTALK_REF
RUN apk add --no-cache git ca-certificates

WORKDIR /src
RUN git clone --no-tags https://github.com/miroslavpejic85/mirotalk /src && \
    git checkout "$MIROTALK_REF" && \
    git log -1 --oneline

# Install production dependencies only. MiroTalk pulls ~300 packages
# incl. socket.io, express, and the optional OIDC / Sentry / ngrok /
# nodemailer integrations; we keep the lot because the server code
# requires() them unconditionally at boot.
RUN npm ci --only=production --no-audit --no-fund --loglevel=warn

# Seed config.js from its template. The upstream Dockerfile does the
# same dance; the prestart hook would otherwise do it at runtime but
# we'd rather have a ready-to-run image.
RUN cp app/src/config.template.js app/src/config.js

# ------------------------------------------------------------ runtime
FROM node:22-alpine

# tini gives us a proper pid-1 so signals (SIGTERM from OpenHost on
# stop/reload) propagate cleanly to node and it exits 0 instead of
# getting SIGKILLed.
RUN apk add --no-cache tini bash ca-certificates openssl

# Copy the fully-installed src tree from the builder. /src/app/ssl/
# contains the committed self-signed cert+key httpolyglot reads at
# startup; don't drop it.
WORKDIR /src
COPY --from=builder /src /src

# Install the OpenHost auth shim -- a small Express middleware
# that short-circuits MiroTalk's /login flow when the OpenHost
# router marks a request as coming from the zone owner via the
# X-OpenHost-Is-Owner: true header. The router strips any
# client-supplied copy of this header before proxying, so it is
# safe to trust as the sole identity signal. The shim file is
# copied alongside server.js so the injected
# `require('./openhost-shim')` resolves correctly;
# install-openhost-shim.sh patches server.js in-place to insert
# that require() before the user-visible route handlers.
COPY openhost-shim.js /patches/openhost-shim.js
COPY patches/install-openhost-shim.sh /patches/install-openhost-shim.sh
RUN chmod +x /patches/install-openhost-shim.sh && \
    /patches/install-openhost-shim.sh && \
    rm -rf /patches

# Install our OpenHost-specific bootstrap script that auto-generates
# persistent secrets, reads the operator's admin password (or mints
# one), and wires the result into process.env before exec-ing node.
COPY entrypoint.sh /usr/local/bin/openhost-entrypoint
RUN chmod +x /usr/local/bin/openhost-entrypoint

# Container listens on 3000 (HTTP, HTTPS via httpolyglot, and the
# socket.io WebSocket upgrade share the same port). OpenHost
# terminates TLS upstream and proxies plain HTTP to us.
EXPOSE 3000

ENV NODE_ENV=production \
    PORT=3000 \
    HOST="" \
    TRUST_PROXY=true \
    CORS_ORIGIN="*" \
    STUN_SERVER_ENABLED=true \
    STUN_SERVER_URL="stun:stun.l.google.com:19302" \
    TURN_SERVER_ENABLED=false \
    OIDC_ENABLED=false \
    CHATGPT_ENABLED=false \
    SLACK_ENABLED=false \
    MATTERMOST_ENABLED=false \
    SENTRY_ENABLED=false \
    EMAIL_ALERT=false \
    STATS_ENABLED=false \
    NGROK_ENABLED=false \
    HOST_PROTECTED=true \
    HOST_USER_AUTH=false

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/openhost-entrypoint"]
CMD ["node", "app/src/server.js"]
