import re
import threading
import time
import uuid

import requests
import socketio
from openhost_test_harness import OpenhostStack

HTML = {"Accept": "text/html,application/xhtml+xml"}
DEFAULT_HOST_PASSWORDS = (("admin", "admin"), ("guest", "guest"))
# Server replies to a socket.io `join`: serverInfo on success, the others are refusals.
JOIN_REPLIES = ("serverInfo", "unauthorized", "roomIsLocked", "roomIsJoinLocked", "roomNotAllowed", "roomBanned")


def _context(stack: OpenhostStack, response: requests.Response | None) -> str:
    seen = "no response" if response is None else f"{response.status_code} {response.headers} {response.text[:500]}"
    return f"last response: {seen}\n\napp logs:\n{stack.app_logs()[-5000:]}"


def _get(stack: OpenhostStack, session: requests.Session | None, path: str) -> requests.Response:
    """GET a page without following redirects, retrying while the app finishes booting."""
    deadline = time.monotonic() + 60
    response = None
    while time.monotonic() < deadline:
        try:
            response = (session or requests).get(f"{stack.url}{path}", headers=HTML, allow_redirects=False, timeout=30)
        except requests.ConnectionError:
            response = None
        if response is not None and response.status_code < 500:
            return response
        time.sleep(2)
    raise AssertionError(f"GET {path} kept failing\n{_context(stack, response)}")


def test_owner_skips_mirotalk_login(stack: OpenhostStack) -> None:
    # Upstream redirects /, /newcall and /logged to its own /login form whenever host protection is on.
    for path in ("/", "/newcall"):
        response = _get(stack, stack.owner_session, path)
        assert response.status_code == 200, f"owner GET {path}\n{_context(stack, response)}"
    response = _get(stack, stack.owner_session, "/login")
    assert response.status_code == 302 and response.headers["Location"] == "/", _context(stack, response)


def test_anonymous_is_sent_to_the_zone_login(stack: OpenhostStack) -> None:
    # The whole app is a public path, so the shim, not the router, keeps guests off the host pages.
    for path in ("/", "/newcall", "/login"):
        response = _get(stack, None, path)
        assert response.status_code == 302, f"anonymous GET {path}\n{_context(stack, response)}"
        assert response.headers["Location"] == f"{stack.router_url}/login", f"anonymous GET {path}: {response.headers}"


def test_guests_can_join_and_leave_a_room(stack: OpenhostStack) -> None:
    response = _get(stack, None, f"/join/{uuid.uuid4()}")
    assert response.status_code == 200, f"anonymous room join\n{_context(stack, response)}"
    # Hanging up sends everyone to REDIRECT_URL=/leave, which only exists in our shim.
    response = _get(stack, None, "/leave")
    assert response.status_code == 200 and "left the meeting" in response.text, _context(stack, response)


def test_host_secrets_are_generated_and_not_logged(stack: OpenhostStack) -> None:
    _get(stack, None, "/leave")
    for username, password in DEFAULT_HOST_PASSWORDS:
        response = requests.post(f"{stack.url}/login", json={"username": username, "password": password}, timeout=30)
        assert response.status_code == 401, f"default host login {username}/{password} works: {response.status_code}"

    secrets = stack.data_dir / "secrets"
    logs = stack.app_logs()
    for name in ("JWT_KEY", "API_KEY_SECRET", "SESSION_SECRET"):
        value = (secrets / name).read_text().strip()
        assert len(value) == 64, f"{name} wasn't generated: {value!r}"
        # Upstream logs its whole config, secrets included, at boot; install-openhost-shim.sh redacts it.
        assert value not in logs, f"{name} appears in the app logs"


def _join_room(
    stack: OpenhostStack, session: requests.Session, room: str, peer_token: str | bool
) -> tuple[str, dict[str, object]]:
    """Join a room over socket.io the way the browser client does; returns the server's reply and its data."""
    client = socketio.Client(reconnection=False)
    replied = threading.Event()
    reply: list[tuple[str, dict[str, object]]] = []
    for event in JOIN_REPLIES:
        client.on(event, lambda data=None, event=event: (reply.append((event, data or {})), replied.set()))
    # MiroTalk's socket.io only accepts the websocket transport. The router authenticates it by the session cookie.
    cookie = session.prepare_request(requests.Request("GET", stack.url)).headers.get("Cookie")
    client.connect(stack.url, headers={"Cookie": cookie} if cookie else {}, transports=["websocket"], wait_timeout=30)
    try:
        client.emit(
            "join",
            {
                "channel": room,
                "peer_uuid": str(uuid.uuid4()),
                "peer_name": "harness",
                "peer_info": {"osName": "Linux", "osVersion": "", "browserName": "harness", "browserVersion": "1"},
                "peer_token": peer_token,
                "create_room_token": None,
                "peer_video": False,
                "peer_audio": False,
                "peer_video_status": False,
                "peer_audio_status": False,
                "peer_screen_status": False,
                "peer_hand_status": False,
                "peer_rec_status": False,
                "peer_privacy_status": False,
            },
        )
        assert replied.wait(30), f"no reply to join\n{_context(stack, None)}"
    finally:
        client.disconnect()
    return reply[0]


def test_owner_can_open_a_room_as_presenter(stack: OpenhostStack) -> None:
    # With host protection on, MiroTalk refuses a join that opens a new room unless it carries the host JWT its login
    # form stores in sessionStorage. The owner skips that form, so openhost-shim.js puts the token in their room page.
    room = str(uuid.uuid4())
    response = _get(stack, stack.owner_session, f"/join/{room}")
    assert response.status_code == 200, f"owner room page\n{_context(stack, response)}"
    match = re.search(r"sessionStorage\.setItem\('peer_token', \"([^\"]+)\"\)", response.text)
    assert match, f"owner room page sets no peer_token\n{_context(stack, response)}"
    event, data = _join_room(stack, stack.owner_session, room, match.group(1))
    assert event == "serverInfo", f"owner opening a room got {event}\n{_context(stack, None)}"
    assert data.get("is_presenter") is True, f"owner isn't the room's presenter: {data}"


def test_guests_cannot_open_a_room(stack: OpenhostStack) -> None:
    # HOST_PROTECTED: only the host may open a new room; guests can only join one that exists.
    room = str(uuid.uuid4())
    response = _get(stack, None, f"/join/{room}")
    assert "peer_token" not in response.text, "a guest's room page carries a host token"
    event, _ = _join_room(stack, requests.Session(), room, False)
    assert event == "unauthorized", f"anonymous visitor opening a room got {event}\n{_context(stack, None)}"
