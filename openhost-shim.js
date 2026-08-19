'use strict';

/**
 * OpenHost auth shim for MiroTalk P2P.
 *
 * When the OpenHost zone owner is logged in, the OpenHost router injects
 * an `X-OpenHost-Is-Owner: true` header into every proxied request. The
 * router strips any client-supplied copy of this header before forwarding
 * (all `X-OpenHost-*` headers from the client are dropped in
 * `web/helpers/proxy.py:_sanitize_forwarded_headers`), so the header is
 * safe to trust as the sole authority on owner identity.
 *
 * When the header is present we bypass MiroTalk's own username/password
 * host-protection flow:
 *
 *   * Add the requester's IP to MiroTalk's `authHost` allowlist
 *     (so subsequent checks via `isAuthorizedIP` return true).
 *   * Force `hostCfg.authenticated = true` on every request, since
 *     MiroTalk's stock `/` and `/newcall` handlers reset it to
 *     false and redirect to `/login` otherwise.
 *   * Register passthrough handlers for `/`, `/newcall`, `/logged`
 *     that skip MiroTalk's login redirect for owners.
 *
 * Guests (non-owner visitors) are unaffected. They can still join
 * rooms via direct URLs -- MiroTalk's `isAllowedRoomAccess` logic
 * lets any visitor into a room that already exists.
 */

const IS_OWNER_HEADER = 'x-openhost-is-owner';

module.exports = function installOpenhostShim({ app, hostCfg, authHost, log, getIP, htmlInjector, views, OIDC }) {
    // Zone domain is used for redirect targets when non-owner
    // browsers hit protected endpoints (/, /newcall, /login). If
    // it's unset we fall back to MiroTalk's native /login page.
    const zoneDomain = process.env.OPENHOST_ZONE_DOMAIN;

    if (!zoneDomain) {
        log.warn('[openhost-shim] OPENHOST_ZONE_DOMAIN not set; /login bypass disabled');
    }

    /**
     * Returns true when the OpenHost router has authenticated the request
     * as coming from the zone owner (indicated by X-OpenHost-Is-Owner: true).
     * The router is the sole authority: it strips any client-supplied copy of
     * this header before forwarding, so no spoofing is possible.
     */
    function isOwner(req) {
        return req.headers[IS_OWNER_HEADER] === 'true';
    }

    // --- middleware: auto-authorize the owner's IP on every request ---
    app.use((req, res, next) => {
        if (!hostCfg.protected) return next();
        if (!isOwner(req)) return next();
        const ip = getIP(req);
        if (!authHost.isAuthorizedIP(ip)) {
            authHost.setAuthorizedIP(ip, true);
            log.info('[openhost-shim] auto-authorized zone owner IP', { ip });
        }
        hostCfg.authenticated = true;
        next();
    });

    // --- route overrides: skip the login redirect for owners ---
    //
    // These handlers are registered BEFORE MiroTalk's own handlers
    // in server.js (because we're called from an early injection
    // point). Express's first-registered-wins route matching lets
    // us pre-empt the stock logic when the visitor is the owner.
    function ownerAwareRender(viewName) {
        return (req, res, next) => {
            if (OIDC.enabled || !hostCfg.protected) return next();
            if (isOwner(req)) {
                // hostCfg.authenticated is already true via the
                // middleware above; render the view directly
                // instead of letting the stock handler bounce
                // to /login.
                return htmlInjector.injectHtml(views[viewName], res);
            }
            // Non-owner on a protected endpoint. If it's a
            // browser page navigation, redirect straight to the
            // OpenHost zone login in one hop instead of letting
            // MiroTalk's stock handler bounce via /login.
            const accept = req.headers.accept || '';
            if (zoneDomain && accept.includes('text/html')) {
                return res.redirect(`https://${zoneDomain}/login`);
            }
            return next();
        };
    }

    app.get('/', ownerAwareRender('landing'));
    app.get('/newcall', ownerAwareRender('newCall'));

    // `/logged` is what MiroTalk redirects to after a successful
    // /login POST -- it checks the caller's IP is in the allowlist
    // and then redirects to `/`. For owners it's already in the
    // allowlist; short-circuit to `/`.
    app.get('/logged', (req, res, next) => {
        if (OIDC.enabled || !hostCfg.protected) return next();
        if (!isOwner(req)) return next();
        return res.redirect('/');
    });

    // `/login` intercept: don't ever show MiroTalk's username+password
    // form to a browser in an OpenHost deployment. Bounce browsers to
    // the OpenHost zone's own /login page instead, so the owner
    // authenticates once against the zone and doesn't need to
    // remember MiroTalk's separate admin password. After a
    // successful zone login they end up on the OpenHost dashboard,
    // from which they can click through to the MiroTalk app tile --
    // at which point the router sets X-OpenHost-Is-Owner on every
    // request and our middleware above auto-authorizes them.
    //
    // For non-browser requests (JSON / asset) and programmatic
    // clients outside an OpenHost deployment, let MiroTalk's own
    // /login handler respond as usual.
    if (zoneDomain) {
        app.get('/login', (req, res, next) => {
            if (OIDC.enabled) return next();
            const accept = req.headers.accept || '';
            if (!accept.includes('text/html')) return next();
            if (isOwner(req)) {
                // Already the owner; skip MiroTalk's login page
                // and drop them on the landing directly.
                return res.redirect('/');
            }
            // OpenHost terminates TLS upstream, so the app
            // only ever sees plain HTTP requests -- but the
            // user-visible scheme is https. Hardcode it.
            return res.redirect(`https://${zoneDomain}/login`);
        });
    }

    // --- public "you have left the meeting" page ---
    //
    // MiroTalk sends everyone to REDIRECT_URL (default /newcall) when
    // they hang up. In an OpenHost deployment /newcall is owner-gated,
    // so a guest who leaves a call gets bounced to the zone login page
    // they can't use. We point REDIRECT_URL at this public /leave page
    // instead (see the Dockerfile ENV), so guests land somewhere sane.
    // MiroTalk has no /leave route of its own, so this is purely
    // additive and never gated.
    const LEAVE_HTML = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>You've left the meeting</title>
<style>
  html,body{height:100%;margin:0}
  body{display:flex;align-items:center;justify-content:center;
       font-family:system-ui,-apple-system,sans-serif;
       background:#111827;color:#e5e7eb;text-align:center;padding:1.5rem}
  .card{max-width:28rem}
  h1{font-size:1.5rem;margin:0 0 .5rem}
  p{color:#9ca3af;line-height:1.5;margin:.25rem 0}
</style>
</head><body>
<div class="card">
  <h1>You've left the meeting</h1>
  <p>Thanks for joining. You can safely close this tab.</p>
  <p>To rejoin, open the meeting link again.</p>
</div>
</body></html>`;

    app.get('/leave', (req, res) => {
        res.set('Content-Type', 'text/html; charset=utf-8');
        res.set('Cache-Control', 'no-store');
        res.send(LEAVE_HTML);
    });

    log.info('[openhost-shim] installed; owner auto-auth active via X-OpenHost-Is-Owner header');
};
