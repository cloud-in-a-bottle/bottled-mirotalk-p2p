import time
import uuid

import requests
from openhost_test_harness import OpenhostStack

HTML = {"Accept": "text/html,application/xhtml+xml"}
DEFAULT_HOST_PASSWORDS = (("admin", "admin"), ("guest", "guest"))


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
