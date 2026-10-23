"""HTTP middlewares: local-only checks (Host / Origin / JSON) and the local API token."""
import hmac

from aiohttp import web

from hub.auth import HEADER

SAFE_METHODS = ('GET', 'HEAD', 'OPTIONS')

# NOTE: script-src could drop 'unsafe-inline' once the inline on*= handlers are converted to
# addEventListener (future pass); style-src likewise once the inline style= attributes go.
# Even so this blocks external/cross-origin script, eval, plugins, and framing.
CSP = ("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; connect-src 'self'; font-src 'self'; object-src 'none'; "
       "base-uri 'self'; frame-ancestors 'none'")
SECURITY_HEADERS = {
    'Content-Security-Policy': CSP,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
}


def _with_security_headers(resp):
    if not resp.prepared:          # a WebSocket is already prepared (headers sent) by then
        for k, v in SECURITY_HEADERS.items():
            resp.headers.setdefault(k, v)
    return resp


def make_local_only(port):
    """Block requests that don't come from the hub's own page. Without this, any website open in
    the same browser could POST to localhost:8766 (drive the glasses, spend API credit) or open
    the log WebSocket. Checks: Host must be localhost (defeats DNS rebinding); a browser Origin,
    when present, must be this hub; state-changing requests must be JSON (a cross-site form or
    plain fetch can't send that without a CORS preflight, which we never approve)."""
    allowed = {f'localhost:{port}', f'127.0.0.1:{port}'}

    @web.middleware
    async def local_only(request, handler):
        try:
            resp = await _local_only(request, handler)
        except web.HTTPException as e:
            _with_security_headers(e)
            raise
        return _with_security_headers(resp)

    async def _local_only(request, handler):
        if request.host not in allowed:
            return web.json_response({'error': 'forbidden host'}, status=403)
        origin = request.headers.get('Origin')
        if origin and origin.split('://', 1)[-1] not in allowed:
            return web.json_response({'error': 'forbidden origin'}, status=403)
        if request.method not in ('GET', 'HEAD') and request.content_type != 'application/json':
            return web.json_response({'error': 'JSON body required'}, status=415)
        return await handler(request)
    return local_only


def make_token_check(token):
    """Require `X-G2Hub-Token: <token>` on every state-changing /api/* request. GETs (read-only
    status, the page itself, the WebSocket) stay open to local same-origin callers."""
    expected = token.encode()

    @web.middleware
    async def require_token(request, handler):
        if request.method not in SAFE_METHODS and request.path.startswith('/api/'):
            got = request.headers.get(HEADER, '').encode()
            if not hmac.compare_digest(got, expected):
                return web.json_response({'error': 'missing or invalid API token (see hub/auth.py)'}, status=401)
        return await handler(request)
    return require_token
