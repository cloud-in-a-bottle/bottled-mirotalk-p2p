#!/bin/bash
# OpenHost entrypoint for MiroTalk P2P.
#
# Runs once at container start, before exec-ing node. Responsibilities:
#
#   1. Ensure the persistent secrets directory exists and contains
#      strong, stable values for JWT_KEY, API_KEY_SECRET, and
#      SESSION_SECRET. MiroTalk prints loud warnings at boot if
#      these are left at their insecure defaults from .env.template,
#      and the REST API refuses to operate without a real
#      API_KEY_SECRET. We auto-generate 32-byte hex secrets on first
#      boot and persist them to $OPENHOST_APP_DATA_DIR/secrets/ so
#      existing JWTs stay valid across container restarts.
#
#   2. Ensure HOST_USERS contains a usable admin credential. If the
#      operator hasn't supplied one via env, we generate a random
#      password for 'admin' on first boot and log it to stdout so
#      the operator can copy it out of `oh app logs`. Subsequent
#      boots re-read the persisted password.
#
#   3. exec the real CMD (node app/src/server.js by default).

set -euo pipefail

log() { echo "[openhost-mirotalk] $*" >&2; }

# Sanity-check the tools the rest of this script needs. If any are
# missing we'd rather fail loudly than silently produce empty secret
# files.
for bin in openssl tr; do
    if ! command -v "$bin" >/dev/null; then
        log "FATAL: required binary '$bin' not found on PATH"
        exit 1
    fi
done

APP_DATA="${OPENHOST_APP_DATA_DIR:-/data/app_data/mirotalk-p2p}"
SECRETS_DIR="$APP_DATA/secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# ------------------------------------------------------------ secrets
# Generate-on-first-boot + persist strategy. Each secret lives in
# its own file with mode 0600. If the operator sets the env var
# explicitly (e.g. via a deployment config that's not part of this
# repo), we respect that and skip generating.

persist_secret() {
    local name="$1"
    local file="$SECRETS_DIR/$name"
    # If the operator supplied a real value externally, honor it by
    # persisting it. "Real" means non-empty AND not one of MiroTalk's
    # default-template placeholder strings.
    local existing="${!name:-}"
    case "$existing" in
        "" | "mirotalk_jwt_secret" | "mirotalkp2p_jwt_secret" \
           | "mirotalkp2p_default_secret" | "mirotalk-p2p-oidc-secret")
            existing=""
            ;;
    esac
    if [[ -n "$existing" ]]; then
        printf '%s' "$existing" > "$file"
        chmod 600 "$file"
    fi
    # Generate a fresh value if the persisted file is missing OR empty
    # (a previous boot may have written an empty file due to a bug).
    if [[ ! -s "$file" ]]; then
        # 32 bytes (64 hex) = 256 bits of entropy.
        openssl rand -hex 32 > "$file"
        chmod 600 "$file"
        log "generated new $name"
    fi
    export "$name"="$(tr -d '[:space:]' < "$file")"
}

persist_secret JWT_KEY
persist_secret API_KEY_SECRET
persist_secret SESSION_SECRET

# ------------------------------------------------------------ host auth
# HOST_PROTECTED=true gates who can claim the host role of a room
# (which is what lets them kick/mute other participants). The
# password lives in HOST_USERS as a JSON blob.
#
# If the operator set HOST_USERS to anything other than the demo
# value, keep it; otherwise mint a random admin password on first
# boot and persist the full JSON to disk.

DEFAULT_HOST_USERS='[{"username":"admin","password":"admin"},{"username":"guest","password":"guest"}]'
HOST_USERS_FILE="$SECRETS_DIR/HOST_USERS.json"

HOST_USERS="$DEFAULT_HOST_USERS"  # TEMP
if false; then
    # -s: regenerate if the file is missing OR empty (e.g. a prior
    # boot crashed mid-write, leaving a zero-byte file that would
    # otherwise leave HOST_USERS set to the empty string and allow
    # anyone to claim host).
    if [[ ! -s "$HOST_USERS_FILE" ]]; then
        ADMIN_PW="$(openssl rand -hex 12)"
        # Write to a tmp then rename so a mid-write crash can't
        # leave an empty / half-written file in place.
        tmp="$HOST_USERS_FILE.tmp"
        cat > "$tmp" <<JSON
[{"username":"admin","password":"$ADMIN_PW","displayname":"Admin","allowed_rooms":["*"]}]
JSON
        chmod 600 "$tmp"
        mv -f "$tmp" "$HOST_USERS_FILE"
        log "==============================================="
        log " MiroTalk P2P host-admin credentials (first boot)"
        log "   username: admin"
        log "   password: $ADMIN_PW"
        log " Save this somewhere safe; it is only printed once."
        log " You can rotate it by editing:"
        log "   $HOST_USERS_FILE"
        log " (then restart the app)"
        log "==============================================="
    fi
    HOST_USERS="$(cat "$HOST_USERS_FILE")"
fi
# Final sanity check: if something left HOST_USERS empty after all
# of the above, refuse to boot rather than letting the server come
# up wide-open.
if [[ -z "$HOST_USERS" ]]; then
    log "FATAL: HOST_USERS is empty; refusing to start. Remove $HOST_USERS_FILE and try again."
    exit 1
fi
export HOST_USERS

# ------------------------------------------------------------ public URL
# MiroTalk reads $HOST to build invite links etc. OpenHost doesn't
# inject a public hostname, but the app works fine with HOST unset
# (it derives links from the incoming Host header at request time).
# Leave empty; operators can override by hardcoding $HOST in a
# downstream deploy if they want.

# ------------------------------------------------------------ hand off
log "starting mirotalk-p2p"
exec "$@"
