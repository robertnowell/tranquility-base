#!/usr/bin/env python3
"""Ask every paid provider the app depends on whether it will actually serve.

Written 7 Sep 2026, the day a log sweep found AssemblyAI's streaming had been
refusing every connection since the 4th with "Insufficient funds" and nothing
had said so for three and a half days. The recovery chain absorbed it, so the
failure record stayed quiet and the only cost was three seconds of silence on
every reply.

The lesson this encodes: a key that authenticates is not a key that serves.
Listing transcripts with the same AssemblyAI key returned 200 the whole time
the streaming socket was being refused, so a shallow "is the key valid" check
would have passed every day of the outage. Each probe below exercises the
exact thing the app asks for, on the exact host it asks.

Exit 0 when every provider serves, 1 when any does not.
"""
import json
import os
import ssl
import socket
import base64
import sys
import urllib.request
import urllib.error

TIMEOUT = 15


def get(url, headers):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.status, json.load(r)


def probe_assemblyai_streaming(key):
    """The websocket the app opens on every capture, handshake and first frame.

    Not the token endpoint: that mints a token happily on an account with no
    balance, so it answered 200 for the whole outage. The refusal arrives on
    the socket, which is why the socket is what we open.
    """
    host = "streaming.assemblyai.com"
    path = "/v3/ws?sample_rate=16000&encoding=pcm_s16le"
    nonce = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {nonce}\r\n"
        f"Sec-WebSocket-Version: 13\r\nAuthorization: {key}\r\n\r\n"
    )
    ctx = ssl.create_default_context()
    sock = ctx.wrap_socket(
        socket.create_connection((host, 443), timeout=TIMEOUT), server_hostname=host)
    try:
        sock.sendall(request.encode())
        data = sock.recv(4096)
        status_line = data.split(b"\r\n", 1)[0].decode(errors="replace")
        if b" 101 " not in data.split(b"\r\n", 1)[0]:
            body = data.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in data else b""
            return False, f"{status_line.strip()} {body[:120].decode(errors='replace').strip()}"
        frame = sock.recv(4096)
        length = frame[1] & 0x7F
        offset = 2 + (2 if length == 126 else 8 if length == 127 else 0)
        payload = frame[offset:].decode(errors="replace")
        # A refusal arrives as a frame too, so read it rather than trusting 101.
        if "Begin" not in payload:
            return False, payload[:160]
        model = json.loads(payload).get("configuration", {}).get("model", "?")
        return True, f"session opens, model {model}"
    finally:
        sock.close()


def probe_assemblyai_files(key):
    status, body = get("https://api.assemblyai.com/v2/transcript?limit=1",
                       {"Authorization": key})
    return status == 200, f"HTTP {status}"


def probe_openai(key):
    """The transcription fallback. If this lapses there is no floor left."""
    status, body = get("https://api.openai.com/v1/models",
                       {"Authorization": f"Bearer {key}"})
    return status == 200, f"HTTP {status}, {len(body.get('data', []))} models"


def probe_elevenlabs(key):
    """The announcement voice, and its quota, which is the slower failure."""
    status, body = get("https://api.elevenlabs.io/v1/user/subscription",
                       {"xi-api-key": key})
    if status != 200:
        return False, f"HTTP {status}"
    used = body.get("character_count") or 0
    limit = body.get("character_limit") or 0
    state = body.get("status", "?")
    if not limit:
        return state == "active", f"status {state}, no quota reported"
    left = limit - used
    percent = 100.0 * left / limit
    ok = state == "active" and percent >= 10.0
    return ok, f"status {state}, {left:,} characters left of {limit:,} ({percent:.1f}%)"


PROBES = [
    ("assemblyai-streaming", "ASSEMBLYAI_API_KEY", probe_assemblyai_streaming,
     "transcribes while you speak; without it every reply waits for a file upload"),
    ("assemblyai-files", "ASSEMBLYAI_API_KEY", probe_assemblyai_files, "recovery rung"),
    ("openai", "OPENAI_API_KEY", probe_openai, "the transcription floor"),
    ("elevenlabs", "ELEVENLABS_API_KEY", probe_elevenlabs, "the announcement voice"),
]


def main():
    worst = 0
    for name, env, probe, why in PROBES:
        key = os.environ.get(env, "")
        if not key:
            print(f"? {name}: {env} is not set")
            worst = 1
            continue
        try:
            ok, detail = probe(key)
        except urllib.error.HTTPError as e:
            ok, detail = False, f"HTTP {e.code} {e.read()[:100].decode(errors='replace')}"
        except Exception as e:  # a probe must never take the check down with it
            ok, detail = False, f"{type(e).__name__}: {e}"
        print(("v " if ok else "x ") + f"{name}: {detail}" + ("" if ok else f"  <- {why}"))
        if not ok:
            worst = 1
    return worst


if __name__ == "__main__":
    sys.exit(main())
