# openhost-mirotalk-p2p

[MiroTalk P2P](https://github.com/miroslavpejic85/mirotalk) packaged
as an OpenHost app.

Peer-to-peer WebRTC video conferencing. The server handles signaling
only (socket.io over WebSocket on a single HTTP port); browsers
establish direct `RTCPeerConnection`s to each other and media flows
browser-to-browser without ever touching the server.

## What you get

- `https://<app>.<your-openhost-host>/` — pick or generate a room
  name, share the URL, talk.
- Built-in chat, screen sharing, client-side recording, emoji
  reactions, raise-hand, participant list, lobby.
- No server-side recording, no SFU, no media relay. The server is
  just a rendezvous point.

## Architecture

```
   browser A ◀──── signaling ────▶  MiroTalk server ◀──── signaling ────▶ browser B
       │    (socket.io over WSS, :443 via OpenHost, :3000 in-container)   │
       │                                                                   │
       └────────── WebRTC media (UDP, direct) ─────────────────────────────┘
```

The container is a small Node.js process (Express + socket.io). No
media ports. No SFU. No persistent database. Total image size ~150MB.

## Ports

| Port     | Purpose                                                 |
|----------|---------------------------------------------------------|
| 3000/tcp | HTTP (and socket.io WebSocket upgrade on the same port) |

No extra ports. WebRTC media goes directly between browsers over
whatever UDP ports ICE ends up negotiating — that doesn't involve
this server at all.

## First-boot secrets

On first boot, `entrypoint.sh` generates and persists three random
secrets to `$OPENHOST_APP_DATA_DIR/secrets/`:

- `JWT_KEY` — signs room-invite JWTs.
- `API_KEY_SECRET` — required by the REST API.
- `SESSION_SECRET` — session cookie signing.

It also generates a random admin password for the `admin` host-role
account and **logs it once** at container start. Grab it with:

```bash
oh app logs mirotalk-p2p | grep -A3 "host-admin credentials"
```

The password is persisted to
`$OPENHOST_APP_DATA_DIR/secrets/HOST_USERS.json`. To rotate it, edit
that file and restart the app.

## Host protection

`HOST_PROTECTED=true` is on by default. That means **anyone** can
enter a room, but to claim the *host* role (the one that can kick,
mute, and enable/disable features for everyone else), a user must log
in at `/login` with the admin credentials above.

If you want to disable host gating and let anyone become host, set
`HOST_PROTECTED=false` in the Dockerfile `ENV` block and redeploy.

If you want to require login to *enter* a room (not just claim host),
set `HOST_USER_AUTH=true`.

### OpenHost auth shim

When the app is deployed on OpenHost and the zone owner is already
logged in to their zone, they do **not** need to log in to MiroTalk
separately. A small Express middleware (`app/src/openhost-shim.js`,
injected into `server.js` at image build time) reads the
`X-OpenHost-Is-Owner: true` header that the OpenHost router injects
on every proxied request from the zone owner. The router strips any
client-supplied copy of this header before forwarding (all
`X-OpenHost-*` headers are dropped in `proxy.py` before the
router's own value is added), so the header is safe to trust as the
sole authority on owner identity.

#### Owner flow

When `X-OpenHost-Is-Owner: true` is present, the shim:

* adds the owner's IP to MiroTalk's in-memory `authHost` allowlist
  on first request, so `isAuthorizedIP` returns true,
* sets `hostCfg.authenticated = true` on every owner request, so
  MiroTalk's stock `/` and `/newcall` handlers don't reset it and
  bounce the owner to `/login`,
* registers pre-empting handlers for `/`, `/newcall`, `/login`,
  and `/logged` that render the landing / new-call pages directly
  for owners instead of MiroTalk's username+password login page.

#### Non-owner flow

When a browser (i.e. a request with `Accept: text/html`) hits
`/`, `/newcall`, or `/login` **without** the owner header, the
shim redirects it to `https://<OPENHOST_ZONE_DOMAIN>/login`. The
user authenticates against their OpenHost zone once and is then
treated as the owner on return. This matches the approach of never
exposing the app's native login UI to end users in an OpenHost
deployment.

Programmatic clients (`Accept: application/json`, curl without an
HTML accept, etc.) are not redirected -- they fall through to
MiroTalk's native `/login` handler, so scripts that want to use
the admin credentials directly still work. This also covers the
case where the app is run outside OpenHost (e.g. local
development) and `OPENHOST_ZONE_DOMAIN` is unset.

#### Guests can still join rooms

Guests with a direct room URL (`/join/<room>`) are unaffected: the
shim only intercepts entry points that MiroTalk itself gates on
host authentication. Anyone with a room URL can enter the room as
a regular participant without any login, matching MiroTalk's
`isAllowedRoomAccess` semantics (rooms that already exist let any
visitor in).

## STUN / TURN

WebRTC needs to punch through NAT. The app defaults to:

- **STUN**: `stun:stun.l.google.com:19302` (public Google STUN).
- **TURN**: disabled.

STUN is enough when both peers are on reasonable networks. It is
**not** enough on:

- Mobile carriers (symmetric NAT).
- Restrictive corporate firewalls that block outgoing UDP to non-443
  ports.

On those networks, two-participant calls will show both tiles
connecting but stuck forever. If that happens to your users, run a
TURN server (e.g. self-hosted [coturn](https://github.com/coturn/coturn),
or a commercial provider) and configure it by editing the Dockerfile's
`ENV` block:

```
TURN_SERVER_ENABLED=true
TURN_SERVER_URL=turn:your-turn.example.com:3478
TURN_SERVER_USERNAME=your-username
TURN_SERVER_CREDENTIAL=your-password
```

Do **not** use the `metered.ca` credentials that ship in MiroTalk's
upstream `.env.template` — those are shared demo credentials that
are rate-limited and visible to every MiroTalk deployer on the
internet.

## Storage

Nothing persistent except the three generated secrets +
`HOST_USERS.json` described above. Room state, peer lists, and chat
history are kept in memory and disappear when the container
restarts. Recording is fully client-side (`MediaRecorder`); files
download to the user's machine.

## Resource requirements

Very light. The default `memory_mb = 512`, `cpu_millicores = 500`
handles dozens of concurrent rooms easily because the server only
relays signaling messages. Scale up only if you enable the optional
ChatGPT / OIDC / Slack / Sentry integrations.

## What's intentionally not enabled

Most of the upstream's optional integrations are off by default to
keep the attack surface small and avoid leaking credentials through
log messages:

- **OIDC / Auth0** (`OIDC_ENABLED=false`)
- **ChatGPT** (`CHATGPT_ENABLED=false`)
- **Slack** (`SLACK_ENABLED=false`)
- **Mattermost** (`MATTERMOST_ENABLED=false`)
- **Sentry** (`SENTRY_ENABLED=false`)
- **nodemailer email alerts** (`EMAIL_ALERT=false`)
- **Umami stats** (`STATS_ENABLED=false`)
- **ngrok** (`NGROK_ENABLED=false`)

Turn them on by editing the Dockerfile `ENV` block and supplying the
corresponding secrets.

## Licensing

MiroTalk is AGPL-3.0. This wrapper is distributed under the same
terms.
