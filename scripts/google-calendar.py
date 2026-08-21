#!/usr/bin/env python3
"""Fetch today's Google Calendar events via OAuth. No external dependencies
beyond the Python standard library.

Usage: google-calendar.py [--days N] [--setup]

First run (or --setup) opens a browser for Google OAuth consent and stores
a refresh token locally at ~/.config/zaatar/google-token.json. Subsequent
runs use the stored token silently.

Outputs a JSON array matching the Google Calendar API shape that
meet-watch.sh expects.
"""

import json, os, sys, time, hashlib, secrets, base64, webbrowser, urllib.request, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# OAuth config - Zaatar's public client (installed app, no secret needed)
# Users can override with their own credentials via env vars.
CLIENT_ID = os.environ.get("ZAATAR_GOOGLE_CLIENT_ID",
    "zaatar-calendar.apps.googleusercontent.com")
REDIRECT_PORT = 8914
REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}"
SCOPES = "https://www.googleapis.com/auth/calendar.readonly"
TOKEN_FILE = Path(os.environ.get("ZAATAR_GOOGLE_TOKEN",
    os.path.expanduser("~/.config/zaatar/google-token.json")))

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
CALENDAR_URL = "https://www.googleapis.com/calendar/v3"


def pkce_pair():
    """Generate PKCE code verifier and challenge (S256)."""
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


class _OAuthHandler(BaseHTTPRequestHandler):
    """Captures the OAuth redirect and extracts the auth code."""
    code = None

    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        _OAuthHandler.code = qs.get("code", [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<html><body><h2>Zaatar: calendar access granted.</h2>"
                         b"<p>You can close this tab.</p></body></html>")

    def log_message(self, *_): pass  # silence logs


def authorize():
    """Run OAuth authorization flow, return tokens dict."""
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(16)

    params = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": SCOPES,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "access_type": "offline",
        "prompt": "consent",
    })

    url = f"{AUTH_URL}?{params}"
    print(f"Opening browser for Google Calendar authorization...", file=sys.stderr)
    webbrowser.open(url)

    server = HTTPServer(("localhost", REDIRECT_PORT), _OAuthHandler)
    server.timeout = 120
    while _OAuthHandler.code is None:
        server.handle_request()
    server.server_close()

    code = _OAuthHandler.code
    if not code:
        print("Authorization failed: no code received.", file=sys.stderr)
        sys.exit(1)

    # Exchange code for tokens
    data = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "code": code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": REDIRECT_URI,
    }).encode()

    req = urllib.request.Request(TOKEN_URL, data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    resp = json.load(urllib.request.urlopen(req))

    tokens = {
        "access_token": resp["access_token"],
        "refresh_token": resp.get("refresh_token", ""),
        "expires_at": time.time() + resp.get("expires_in", 3600),
    }
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(json.dumps(tokens))
    TOKEN_FILE.chmod(0o600)
    print("Token saved.", file=sys.stderr)
    return tokens


def refresh_access_token(tokens):
    """Refresh the access token using the stored refresh token."""
    data = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "refresh_token": tokens["refresh_token"],
        "grant_type": "refresh_token",
    }).encode()

    req = urllib.request.Request(TOKEN_URL, data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    resp = json.load(urllib.request.urlopen(req))

    tokens["access_token"] = resp["access_token"]
    tokens["expires_at"] = time.time() + resp.get("expires_in", 3600)
    TOKEN_FILE.write_text(json.dumps(tokens))
    return tokens


def get_tokens():
    """Load tokens from file, refresh if needed, or run auth flow."""
    if TOKEN_FILE.exists():
        tokens = json.loads(TOKEN_FILE.read_text())
        if tokens.get("expires_at", 0) < time.time() + 60:
            if tokens.get("refresh_token"):
                try:
                    return refresh_access_token(tokens)
                except Exception:
                    pass  # fall through to re-auth
            return authorize()
        return tokens
    return authorize()


def fetch_events(access_token, days=1):
    """Fetch calendar events for the next N days."""
    from datetime import datetime, timezone, timedelta

    now = datetime.now(timezone.utc)
    start_of_day = now.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start_of_day + timedelta(days=days)

    params = urllib.parse.urlencode({
        "timeMin": start_of_day.isoformat(),
        "timeMax": end.isoformat(),
        "singleEvents": "true",
        "orderBy": "startTime",
        "maxResults": "50",
    })

    url = f"{CALENDAR_URL}/calendars/primary/events?{params}"
    req = urllib.request.Request(url,
        headers={"Authorization": f"Bearer {access_token}"})

    try:
        resp = json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        if e.code == 401:
            print("Token expired, re-authorizing...", file=sys.stderr)
            return None  # caller should re-auth
        raise

    return resp.get("items", [])


def main():
    days = 1
    if "--days" in sys.argv:
        idx = sys.argv.index("--days")
        if idx + 1 < len(sys.argv):
            days = int(sys.argv[idx + 1])

    if "--setup" in sys.argv:
        authorize()
        print("Setup complete.", file=sys.stderr)
        return

    tokens = get_tokens()
    events = fetch_events(tokens["access_token"], days)

    if events is None:
        # Token was invalid, re-auth and retry
        tokens = authorize()
        events = fetch_events(tokens["access_token"], days)

    print(json.dumps(events or [], indent=2))


if __name__ == "__main__":
    main()
