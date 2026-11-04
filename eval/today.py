#!/usr/bin/env python3
"""Runs the scripted dictations through today's QuickScribe helper on this Mac,
over its normal local address. Standard library only.
Usage: today.py speech <corpus.json> <audio-dir> | today.py clean <corpus.json> <mode>
"""
import json, sys, time, urllib.request, uuid

BASE = "http://127.0.0.1:8790"

def post(req, timeout=120):
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def transcribe(path):
    b = uuid.uuid4().hex
    body = (f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="c.wav"\r\n'
            'Content-Type: audio/wav\r\n\r\n').encode() + open(path, "rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"{BASE}/transcribe?partial=false", data=body,
                                 headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    return post(req)["text"]

def polish(text, mode):
    req = urllib.request.Request(f"{BASE}/polish", data=json.dumps({"text": text, "profile": mode}).encode(),
                                 headers={"Content-Type": "application/json"})
    return post(req)

items = json.load(open(sys.argv[2]))
for it in items:
    t0 = time.time()
    try:
        if sys.argv[1] == "speech":
            row = {"id": it["id"], "text": transcribe(f"{sys.argv[3]}/{it['id']}.wav")}
        else:
            p = polish(it["raw"], sys.argv[3])
            row = {"id": it["id"], "text": p["text"]}
            if p.get("degraded"):
                row["error"] = "degraded"
    except Exception as exc:
        row = {"id": it["id"], "error": repr(exc)}
    row["seconds"] = time.time() - t0
    print(json.dumps(row), flush=True)
