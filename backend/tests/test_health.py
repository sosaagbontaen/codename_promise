"""Can a client find out whether it is configured correctly, without doing real work?

Every other authenticated endpoint transcribes audio, calls a model or writes to Notion, so
the only way to test a key was to try to use it and watch a recording fail. In the app that
read as "it is broken", with no way to tell a wrong address from a wrong key.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.config import Settings
from app.connections import InMemoryConnectionStore
from app.main import create_app
from app.services import InMemoryNotion


def make_client(api_key=None):
    app = create_app(
        settings=Settings(api_key=api_key, formatter_version="test-1"),
        notion=InMemoryNotion(),
        connections=InMemoryConnectionStore(),
    )
    return TestClient(app)


def test_auth_check_accepts_the_configured_key():
    client = make_client(api_key="secret")
    response = client.get("/auth/check", headers={"Authorization": "Bearer secret"})
    assert response.status_code == 200
    assert response.json() == {"ok": True}


def test_auth_check_rejects_a_wrong_key():
    client = make_client(api_key="secret")
    assert client.get(
        "/auth/check", headers={"Authorization": "Bearer nonsense"}
    ).status_code == 401


def test_auth_check_rejects_a_missing_key():
    assert make_client(api_key="secret").get("/auth/check").status_code == 401


def test_auth_check_is_open_when_no_key_is_configured():
    """Truthfully open. With no key set there is nothing for a client to get wrong."""
    assert make_client().get("/auth/check").status_code == 200


def test_auth_check_does_no_work():
    """No providers, no state, no side effects — it must stay cheap enough to call freely."""
    client = make_client()
    assert client.get("/auth/check").json() == {"ok": True}


def test_health_says_whether_a_key_is_required():
    """So the app can tell "this server wants a key" from "your key is wrong"."""
    assert make_client(api_key="secret").get("/health").json()["auth_required"] is True
    assert make_client().get("/health").json()["auth_required"] is False


def test_root_says_the_server_is_up():
    """Opening the address in a browser is how people check. It should answer."""
    response = make_client().get("/")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_root_gives_nothing_away():
    """/health is the place for configuration, and a passer-by has no need of it."""
    body = make_client(api_key="secret").get("/").json()
    assert "auth_required" not in body
    assert "models" not in body
