#!/usr/bin/env python3
"""Builds a corpus whose raw text is a recognizer's transcript, so cleanup is scored
on what it would really receive. Usage: pipeline_corpus.py <corpus> <speech.jsonl> <out>"""
import json, sys
rows = {json.loads(l)["id"]: json.loads(l) for l in open(sys.argv[2])}
out = [dict(c, raw=rows[c["id"]].get("text", "")) for c in json.load(open(sys.argv[1]))]
json.dump(out, open(sys.argv[3], "w"), ensure_ascii=False, indent=1)
