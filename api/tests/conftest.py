import pytest
from httpx import ASGITransport, AsyncClient

from main import app


@pytest.fixture(autouse=True)
def _fresh_rate_limit_budget():
    """Every test starts with an empty sliding window.

    The limiter is a process-wide singleton and the ASGI test client always
    presents the same peer address, so without this a long module of
    expensive-tier requests would start failing with 429 part-way through.
    """
    from api.utils import rate_limiter

    rate_limiter._limiter = None
    yield
    rate_limiter._limiter = None


@pytest.fixture(autouse=True)
def _fresh_upstream_guard(monkeypatch):
    """No request pacing, no carried-over cooldown, no learned theme images.

    Pacing would only slow the suite down, a cooldown tripped by one test's
    fake 429 must not leak into the next, and a learned light→dark image map
    would let a later test skip the dark fetch it asserts on.
    """
    from utils.http_client import theme_image_map, upstream_guard

    upstream_guard.reset()
    theme_image_map.clear()
    monkeypatch.setattr(upstream_guard, "min_interval", 0.0)
    yield
    upstream_guard.reset()
    theme_image_map.clear()


@pytest.fixture(autouse=True)
def _offline_logo_enrichment(monkeypatch):
    """Keep list-logo enrichment from reaching vlr.gg in tests.

    Tests that exercise enrichment install their own fake fetch over this one.
    """
    from api import team_logo_enrichment
    from utils.team_logos import team_logo_store

    async def no_fetch(match_id, store=team_logo_store):
        store.record_miss(match_id)
        return False

    team_logo_store.clear()
    team_logo_enrichment._reset_for_tests()
    monkeypatch.setattr(team_logo_enrichment, "fetch_match_logos", no_fetch)
    yield
    team_logo_store.clear()
    team_logo_enrichment._reset_for_tests()


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def async_client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client
