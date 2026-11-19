import os
import tempfile

# Configure the app for tests BEFORE it is imported: a throwaway SQLite file
# instead of Postgres, and no API key so the AI code uses its rule-based path.
_db_file = os.path.join(tempfile.mkdtemp(), "test.db")
os.environ["DATABASE_URL"] = f"sqlite:///{_db_file}"
os.environ["ANTHROPIC_API_KEY"] = ""
os.environ["APP_ENV"] = "test"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


@pytest.fixture()
def client():
    with TestClient(app) as c:  # runs the lifespan (creates tables)
        yield c
