#!/usr/bin/env python3
"""Poll App Store Connect for the processing state of a TestFlight build.
ES256 JWT signed via `openssl` (no PyJWT dependency). Creds from
~/.config/airpad/testflight.env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, ASC_APP_ID.
Usage: asc_poll.py <build_number>
"""
import base64, json, os, subprocess, sys, time, urllib.request

def env(path):
    d = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"): continue
        line = line[7:] if line.startswith("export ") else line
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip().strip('"').strip("'")
    return d

def b64url(b): return base64.urlsafe_b64encode(b).rstrip(b"=")

def sign_jwt(key_id, issuer_id, key_path):
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + 1000, "aud": "appstoreconnect-v1"}
    signing = b64url(json.dumps(header).encode()) + b"." + b64url(json.dumps(payload).encode())
    # openssl produces DER ECDSA; convert to raw r||s (64 bytes) for JOSE.
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing, capture_output=True).stdout
    # Parse DER: 0x30 len 0x02 rlen r 0x02 slen s
    i = 2
    if der[1] & 0x80: i += der[1] & 0x7f
    def read_int(buf, i):
        assert buf[i] == 0x02
        ln = buf[i+1]; val = buf[i+2:i+2+ln]
        return val.lstrip(b"\x00").rjust(32, b"\x00"), i+2+ln
    r, i = read_int(der, i)
    s, i = read_int(der, i)
    return (signing + b"." + b64url(r + s)).decode()

def api(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

def main():
    build = sys.argv[1] if len(sys.argv) > 1 else None
    e = env(os.path.expanduser("~/.config/airpad/testflight.env"))
    key_path = os.path.expanduser(e["ASC_KEY_PATH"])
    app_id = e["ASC_APP_ID"]
    for attempt in range(1, 41):
        token = sign_jwt(e["ASC_KEY_ID"], e["ASC_ISSUER_ID"], key_path)
        url = (f"https://api.appstoreconnect.apple.com/v1/builds"
               f"?filter[app]={app_id}&sort=-uploadedDate&limit=5"
               f"&fields[builds]=version,processingState,uploadedDate")
        try:
            data = api(url, token)
        except Exception as ex:
            print(f"[poll {attempt}] API error: {ex}", flush=True); time.sleep(90); continue
        match = None
        for b in data.get("data", []):
            v = b["attributes"].get("version")
            if build is None or v == str(build):
                match = b; break
        if match is None:
            print(f"[poll {attempt}] build {build} not visible yet", flush=True)
        else:
            state = match["attributes"]["processingState"]
            print(f"[poll {attempt}] build {match['attributes']['version']} → {state}", flush=True)
            if state == "VALID":
                print(f">>> build {build} READY", flush=True); return 0
            if state in ("INVALID", "FAILED"):
                print(f">>> build {build} {state}", flush=True); return 1
        time.sleep(90)
    print(">>> timed out waiting for processing", flush=True); return 2

if __name__ == "__main__":
    sys.exit(main())
