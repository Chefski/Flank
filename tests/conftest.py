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


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def async_client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client
