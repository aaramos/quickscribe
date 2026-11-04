#!/usr/bin/env python3
"""Scores test runs. Usage: score.py <results-dir>
Reads corpus.json plus speech_*.jsonl and clean_*.jsonl from the folder."""
import glob, json, os, re, statistics, sys

ROOT = sys.argv[1]
CORPUS = {c["id"]: c for c in json.load(open(f"{ROOT}/corpus.json"))}
UNITS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split())}
TENS = {w: (i + 2) * 10 for i, w in enumerate("twenty thirty forty fifty sixty seventy eighty ninety".split())}
DROP = {"um", "uh", "hmm", "er", "ah"}

def words(text):
    text = text.lower().replace("’", "'").replace("-", " ")
    text = re.sub(r"(?<=\d),(?=\d)", "", text)
    toks = re.findall(r"[a-z0-9']+(?:\.\d+)?", text)
    out = []
    for t in toks:
        if t in DROP or t == "oh":
            continue
        if t in TENS:
            out.append(str(TENS[t]))
        elif t in UNITS:
            if out and out[-1].isdigit() and int(out[-1]) % 10 == 0 and int(out[-1]) >= 20 and UNITS[t] < 10:
                out[-1] = str(int(out[-1]) + UNITS[t])
            else:
                out.append(str(UNITS[t]))
        else:
            out.append(t)
    return out

def distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def has(text, needle):
    t, n = text.lower().replace("’", "'"), needle.lower()
    if n == "?":
        return "?" in t
    return re.search(rf"(?<![a-z0-9]){re.escape(n)}(?![a-z0-9])", t) is not None

def load(path):
    return {json.loads(l)["id"]: json.loads(l) for l in open(path) if l.strip().startswith("{")}

def one(x):
    return f"{x:.1f}"

print("SPEECH  (error rate on spoken words, lower is better)")
for path in sorted(glob.glob(f"{ROOT}/speech_*.jsonl")):
    rows = load(path)
    errs = refs = 0
    worst = []
    ok = [r for r in rows.values() if "text" in r]
    for r in ok:
        ref, hyp = words(CORPUS[r["id"]]["raw"]), words(r["text"])
        d = distance(ref, hyp)
        errs += d; refs += len(ref)
        worst.append((d / max(1, len(ref)), r["id"]))
    sec = [r["seconds"] for r in ok]
    print(f"  {os.path.basename(path)[7:-6]:22s} errors {one(100*errs/max(1,refs))}%  median {one(statistics.median(sec))} s  failed {len(rows)-len(ok)}  worst {[i for _, i in sorted(worst)[-3:]]}")

print("\nCLEANUP  (a dictation passes when every required fact survives and no abandoned word remains)")
head = f"  {'version':32s} pass  wrong-num  answered  refused  caught  errors  median s  slowest s"
print(head)
for path in sorted(glob.glob(f"{ROOT}/clean_*.jsonl")):
    rows = load(path)
    passed = wrong = answered = refused = errored = guarded = 0
    misses = []
    secs = []
    for id_, c in CORPUS.items():
        r = rows.get(id_, {"error": "missing"})
        if "seconds" in r and r.get("seconds"):
            secs.append(r["seconds"])
        if "text" not in r or r.get("error"):
            if "refused" in str(r.get("error")):
                refused += 1
            else:
                errored += 1
            misses.append(f"{id_}:{str(r.get('error'))[:24]}")
            continue
        t = r["text"]
        guarded += 1 if "guarded" in r else 0
        lost = [g[0] for g in c["must"] if not any(has(t, a) for a in g)]
        kept = [n for n in c["never"] if has(t, n)]
        if lost or kept:
            misses.append(f"{id_}:{'lost ' + '/'.join(lost) if lost else ''}{' kept ' + '/'.join(kept) if kept else ''}")
        else:
            passed += 1
        if c["category"] == "correct_number" and kept:
            wrong += 1
        if c["category"] in ("question", "command") and lost:
            answered += 1
    med = one(statistics.median(secs)) if secs else "0.0"
    top = one(max(secs)) if secs else "0.0"
    name = os.path.basename(path)[6:-6]
    print(f"  {name:32s} {passed:2d}/{len(CORPUS)}  {wrong:9d}  {answered:8d}  {refused:7d}  {guarded:6d}  {errored:6d}  {med:>8s}  {top:>9s}")
    print("      misses:", "; ".join(misses) if misses else "none")
