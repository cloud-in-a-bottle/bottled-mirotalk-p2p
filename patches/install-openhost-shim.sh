#!/bin/sh
# Patches MiroTalk's server.js at image build time.
#
# Three patches:
#
#   1. Copy our openhost-shim.js module next to the server so
#      `require('./openhost-shim')` resolves from server.js.
#
#   2. Insert `require('./openhost-shim')({app, hostCfg, authHost,
#      log, getIP, htmlInjector, views, OIDC})` right before the
#      `/profile` route registration -- that's after the OIDC
#      middleware is fully set up but before any user-visible
#      route handlers, so our pre-empt routes (`/`, `/newcall`,
#      `/logged`) win against the stock ones.
#
#   3. Redact the startup "Server config" dump. Upstream MiroTalk
#      logs its ENTIRE config object at log.info on every boot
#      (`log.info('Server config', getServerConfig(...))`), which
#      includes JWT_KEY, api_key_secret, and the HOST_USERS admin
#      password. OpenHost surfaces container stdout as the
#      owner-facing app log, so that dumps secrets into the logs.
#      We drop the config argument so only a bland marker is logged.
#
# The patch is idempotent: re-running it doesn't double-inject.

set -eu

SERVER_JS="/src/app/src/server.js"
SHIM_DEST="/src/app/src/openhost-shim.js"
SHIM_SRC="/patches/openhost-shim.js"

if [ ! -f "$SERVER_JS" ]; then
    echo "[install-openhost-shim] FATAL: $SERVER_JS not found" >&2
    exit 1
fi
if [ ! -f "$SHIM_SRC" ]; then
    echo "[install-openhost-shim] FATAL: $SHIM_SRC not found" >&2
    exit 1
fi

cp "$SHIM_SRC" "$SHIM_DEST"

if grep -q "openhost-shim" "$SERVER_JS"; then
    echo "[install-openhost-shim] already patched; skipping"
    exit 0
fi

# Anchor: the comment line right above the /profile route. Unique
# in stable-9155/master at time of writing.
ANCHOR='// Route to display user information'
if ! grep -q "$ANCHOR" "$SERVER_JS"; then
    echo "[install-openhost-shim] FATAL: anchor comment not found in $SERVER_JS" >&2
    echo "[install-openhost-shim] Upstream may have changed; regenerate the patch." >&2
    exit 1
fi

# Insert the require() call immediately BEFORE the anchor line.
# We use a small node script to avoid sed quoting headaches with the
# multi-line snippet. When node reads a script from stdin the
# filename "-" shows up as argv[1], so our target path is argv[2].
node - "$SERVER_JS" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const original = fs.readFileSync(file, 'utf8');
const anchor = '// Route to display user information';
const snippet = `// --- OpenHost auth shim (installed at image build time) ---
// Pre-empts MiroTalk's /login flow when the OpenHost router marks a
// request as coming from the zone owner (X-OpenHost-Is-Owner: true).
// See openhost-shim.js for details.
require('./openhost-shim')({
    app,
    hostCfg,
    authHost,
    log,
    getIP,
    htmlInjector,
    views,
    OIDC,
});

`;
if (original.includes('openhost-shim')) {
    console.log('[install-openhost-shim] already patched');
    process.exit(0);
}
let patched = original.replace(anchor, snippet + anchor);
if (patched === original) {
    console.error('[install-openhost-shim] shim injection did not apply');
    process.exit(1);
}

// Redact the "Server config" startup dump (it prints JWT_KEY,
// api_key_secret, and the HOST_USERS admin password to stdout).
const configLogRe = /log\.info\('Server config', getServerConfig\([^)]*\)\);/g;
const nConfigLogs = (patched.match(configLogRe) || []).length;
if (nConfigLogs > 0) {
    patched = patched.replace(
        configLogRe,
        "log.info('Server config loaded (object omitted by openhost: it contains secrets)');",
    );
    console.log('[install-openhost-shim] redacted ' + nConfigLogs + ' Server config log(s)');
} else {
    // Non-fatal: upstream may have changed the log call. Warn loudly
    // so the leak doesn't silently return on an upstream bump.
    console.error('[install-openhost-shim] WARNING: no "Server config" log found to redact; '
        + 'verify server.js no longer dumps secrets to stdout after an upstream bump');
}

fs.writeFileSync(file, patched);
console.log('[install-openhost-shim] patched server.js');
NODE
