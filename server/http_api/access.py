"""Cross-origin access and the optional API token, applied to every request.

Browser tools on another origin (an infinite-canvas page, a local agent UI) may call the API only when
their origin is listed in H3_CORS_ORIGINS. With H3_API_TOKEN set, /api/* except /api/health needs
`Authorization: Bearer <token>`; /files/* stays open because media elements cannot send headers and
file names are unguessable random ids that only the authenticated API reveals.
"""

import hmac

from aiohttp import web

PUBLIC_API = frozenset({"/api/health"})
ALLOW_METHODS = "GET, POST, DELETE, OPTIONS"
ALLOW_HEADERS = "Authorization, Content-Type"
EXPOSE_HEADERS = "X-Total-Count"


def allowed_origin(origin, origins):
    if not origin or not origins:
        return None
    return origin if "*" in origins or origin.rstrip("/") in origins else None


def authorized(request, token):
    scheme, _, value = request.headers.get("Authorization", "").partition(" ")
    return scheme.lower() == "bearer" and hmac.compare_digest(value.strip().encode(), token.encode())


def access_middleware(settings):
    origins = frozenset(settings.cors_origins)
    token = settings.api_token

    @web.middleware
    async def middleware(request, handler):
        origin = allowed_origin(request.headers.get("Origin"), origins)
        if origin and request.method == "OPTIONS" and "Access-Control-Request-Method" in request.headers:
            response = web.Response(
                status=204,
                headers={
                    "Access-Control-Allow-Methods": ALLOW_METHODS,
                    "Access-Control-Allow-Headers": ALLOW_HEADERS,
                    "Access-Control-Max-Age": "600",
                },
            )
        elif (
            token
            and request.path.startswith("/api/")
            and request.path not in PUBLIC_API
            and not authorized(request, token)
        ):
            response = web.json_response(
                {"error": "missing or invalid API token"},
                status=401,
                headers={"WWW-Authenticate": 'Bearer realm="h3-studio"'},
            )
        else:
            try:
                response = await handler(request)
            except web.HTTPException as exc:
                if origin:
                    cors_headers(exc.headers, origin)
                raise
        if origin:
            cors_headers(response.headers, origin)
        return response

    return middleware


def cors_headers(headers, origin):
    headers["Access-Control-Allow-Origin"] = origin
    headers["Access-Control-Expose-Headers"] = EXPOSE_HEADERS
    headers.add("Vary", "Origin")
