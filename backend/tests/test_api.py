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
    r = client.post("/api/ideas", json={"title": "  Dark mode  ", "description": "Easier on the eyes"})
    assert r.status_code == 201
    created = r.json()
    assert created["title"] == "Dark mode"
    assert created["id"] > 0

    ideas = client.get("/api/ideas").json()
    assert ideas[0]["id"] == created["id"]  # newest first


def test_create_idea_validation(client):
    assert client.post("/api/ideas", json={"title": ""}).status_code == 422
    assert client.post("/api/ideas", json={"title": "   "}).status_code == 422
    assert client.post("/api/ideas", json={}).status_code == 422
