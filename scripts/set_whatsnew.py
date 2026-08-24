#!/usr/bin/env python3
"""Set a TestFlight build's "What to Test" (whatsNew) note — used to label lanes
so concurrent arcs' builds are distinguishable in TestFlight.
Usage: set_whatsnew.py <build_number> "<text>"   (locale en-US)
Reuses asc_poll's env loader + ES256 JWT signing (no extra deps)."""
import json, os, sys, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_poll import env, sign_jwt

BASE = "https://api.appstoreconnect.apple.com"

def call(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as ex:
        print("HTTP", ex.code, ex.read().decode()[:500]); raise

def main():
    if len(sys.argv) < 3:
        print("usage: set_whatsnew.py <build_number> \"<text>\""); return 2
    build, text = sys.argv[1], sys.argv[2]
    e = env(os.path.expanduser("~/.config/airpad/testflight.env"))
    token = sign_jwt(e["ASC_KEY_ID"], e["ASC_ISSUER_ID"], os.path.expanduser(e["ASC_KEY_PATH"]))
    app = e["ASC_APP_ID"]
    b = call("GET", f"/v1/builds?filter[app]={app}&filter[version]={build}&limit=1", token)
    if not b.get("data"):
        print(f"build {build} not found in ASC yet"); return 1
    bid = b["data"][0]["id"]
    locs = call("GET", f"/v1/builds/{bid}/betaBuildLocalizations", token)
    existing = next((l for l in locs.get("data", []) if l["attributes"]["locale"] == "en-US"), None)
    if existing:
        call("PATCH", f"/v1/betaBuildLocalizations/{existing['id']}", token,
             {"data": {"type": "betaBuildLocalizations", "id": existing["id"],
                       "attributes": {"whatsNew": text}}})
        print("patched en-US localization")
    else:
        call("POST", "/v1/betaBuildLocalizations", token,
             {"data": {"type": "betaBuildLocalizations",
                       "attributes": {"locale": "en-US", "whatsNew": text},
                       "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
        print("created en-US localization")
    print(f">>> whatsNew set for build {build}: {text!r}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
