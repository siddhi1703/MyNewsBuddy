import asyncio
import os
import time
from collections import defaultdict, deque
from dataclasses import dataclass

import httpx
from fastapi import Header, HTTPException, status


DEFAULT_SUPABASE_URL = "https://rajxtpjbwhcilvwyvrkz.supabase.co"
DEFAULT_SUPABASE_PUBLISHABLE_KEY = "sb_publishable_LYt5UDCkuktF5D7chsiWIA_AQanjNQT"


@dataclass(frozen=True)
class AuthenticatedUser:
    id: str
    email: str | None = None


def auth_is_configured() -> bool:
    # Report whether Supabase was *explicitly* configured via environment
    # variables. The service still falls back to a built-in default project so
    # the app runs out of the box, but /health must not claim the operator
    # configured authentication when they did not (that fallback silently points
    # at someone else's project).
    return bool(
        os.getenv("SUPABASE_URL", "").strip()
        and os.getenv("SUPABASE_PUBLISHABLE_KEY", "").strip()
    )


def _supabase_settings() -> tuple[str, str]:
    project_url = os.getenv("SUPABASE_URL", DEFAULT_SUPABASE_URL).strip().rstrip("/")
    publishable_key = os.getenv(
        "SUPABASE_PUBLISHABLE_KEY",
        DEFAULT_SUPABASE_PUBLISHABLE_KEY,
    ).strip()
    return project_url, publishable_key


def _bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Sign in before using the AI companion.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    scheme, separator, token = authorization.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="The authentication token is invalid.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return token.strip()


async def verify_supabase_token(
    token: str,
    *,
    client: httpx.AsyncClient | None = None,
) -> AuthenticatedUser:
    project_url, publishable_key = _supabase_settings()
    if not project_url or not publishable_key:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Backend authentication is not configured.",
        )

    owns_client = client is None
    auth_client = client or httpx.AsyncClient(timeout=10)
    try:
        response = await auth_client.get(
            f"{project_url}/auth/v1/user",
            headers={
                "apikey": publishable_key,
                "Authorization": f"Bearer {token}",
            },
        )
    except httpx.HTTPError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not verify your session right now.",
        ) from error
    finally:
        if owns_client:
            await auth_client.aclose()

    if response.status_code in {401, 403}:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Your session has expired. Please sign in again.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if response.status_code >= 400:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not verify your session right now.",
        )

    try:
        payload = response.json()
        user_id = payload["id"]
    except (KeyError, TypeError, ValueError) as error:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Supabase returned an invalid user session.",
            headers={"WWW-Authenticate": "Bearer"},
        ) from error

    if not isinstance(user_id, str) or not user_id.strip():
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Supabase returned an invalid user session.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    email = payload.get("email")
    return AuthenticatedUser(
        id=user_id,
        email=email if isinstance(email, str) else None,
    )


async def require_authenticated_user(
    authorization: str | None = Header(default=None),
) -> AuthenticatedUser:
    return await verify_supabase_token(_bearer_token(authorization))


class PerUserRateLimiter:
    # Guard against unbounded growth: distinct user ids accumulate one deque each
    # and never return. Above this many tracked users, sweep out the stale ones.
    MAX_TRACKED_USERS = 50_000

    def __init__(self, environment_key: str, default_limit: int) -> None:
        self.environment_key = environment_key
        self.default_limit = default_limit
        self._requests: dict[str, deque[float]] = defaultdict(deque)
        self._lock = asyncio.Lock()

    def _configured_limit(self) -> int:
        # A misconfigured env value (empty or non-numeric) must not take the
        # whole endpoint down with a ValueError on every request.
        raw = os.getenv(self.environment_key)
        if raw is None:
            return self.default_limit
        try:
            return max(1, int(raw.strip()))
        except ValueError:
            return self.default_limit

    async def check(self, user_id: str) -> None:
        limit = self._configured_limit()
        window_seconds = 60.0
        now = time.monotonic()

        async with self._lock:
            requests = self._requests[user_id]
            while requests and requests[0] <= now - window_seconds:
                requests.popleft()

            if len(requests) >= limit:
                retry_after = max(1, int(window_seconds - (now - requests[0])))
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail=(
                        "You have sent several AI questions quickly. "
                        "Please wait a moment and try again."
                    ),
                    headers={"Retry-After": str(retry_after)},
                )

            requests.append(now)
            if len(self._requests) > self.MAX_TRACKED_USERS:
                self._evict_stale(now - window_seconds)

    def _evict_stale(self, cutoff: float) -> None:
        stale = [
            user_id
            for user_id, timestamps in self._requests.items()
            if not timestamps or timestamps[-1] <= cutoff
        ]
        for user_id in stale:
            del self._requests[user_id]


chat_rate_limiter = PerUserRateLimiter("CHAT_REQUESTS_PER_MINUTE", 10)
routing_rate_limiter = PerUserRateLimiter("ROUTING_REQUESTS_PER_MINUTE", 20)


async def authorize_chat_request(
    authorization: str | None = Header(default=None),
) -> AuthenticatedUser:
    user = await require_authenticated_user(authorization)
    await chat_rate_limiter.check(user.id)
    return user


async def authorize_routing_request(
    authorization: str | None = Header(default=None),
) -> AuthenticatedUser:
    user = await require_authenticated_user(authorization)
    await routing_rate_limiter.check(user.id)
    return user
