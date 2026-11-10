import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(tmp_path, monkeypatch):
    from center import store
    monkeypatch.setattr(store, "DATA_DIR", tmp_path)
    monkeypatch.setattr(store, "_conn", None)
    from center.main import app
    return TestClient(app)


@pytest.fixture
def token():
    from center import auth

    def make(*scopes):
        return {"Authorization": f"Bearer {auth.create_token('test', list(scopes))[1]}"}
    return make
