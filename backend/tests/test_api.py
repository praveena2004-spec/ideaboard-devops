from app.config import settings


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_ready_ok(client):
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_ready_simulated_failure(client, monkeypatch):
    monkeypatch.setattr(settings, "simulate_unhealthy", True)
    assert client.get("/ready").status_code == 503


def test_version(client):
    body = client.get("/api/version").json()
    assert set(body) == {"version", "environment"}


def test_create_and_list_ideas(client):
    r = client.post("/api/ideas", json={"content": "  My new idea  "})
    assert r.status_code == 201
    created = r.json()
    assert set(created) == {"id", "content", "created_at"}
    assert created["content"] == "My new idea"
    assert created["id"] > 0

    ideas = client.get("/api/ideas").json()
    assert isinstance(ideas, list)
    assert ideas[0]["id"] == created["id"]  # newest first


def test_create_idea_validation(client):
    assert client.post("/api/ideas", json={"content": ""}).status_code == 422
    assert client.post("/api/ideas", json={"content": "   "}).status_code == 422
    assert client.post("/api/ideas", json={}).status_code == 422


def test_db_down_at_startup_is_not_fatal(client, monkeypatch):
    """A database that isn't up yet must make the pod not-ready, never crash it."""
    import app.main as main

    def boom(**_):
        raise RuntimeError("connection refused")

    monkeypatch.setattr(main, "_schema_ready", False)
    monkeypatch.setattr(main.Base.metadata, "create_all", boom)
    assert main.ensure_schema() is False                       # no exception
    assert client.get("/health").status_code == 200            # liveness unaffected
    assert client.get("/ready").status_code == 503             # traffic withheld
    monkeypatch.undo()
    assert client.get("/ready").status_code == 200             # recovers by itself
