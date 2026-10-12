#!/usr/bin/env python3
"""T's-library guard (live-6 (3)). The same file is committed in Ops, AirPad, airpad-host and curiousobjects-site.

    fpscan.py staged            pre-commit: scan the lines this commit ADDS (and new paths); exit 1 on a match
    fpscan.py msg <file>        commit-msg: scan the commit message
    fpscan.py files <path>...   scan whole files (tests, spot checks)
    fpscan.py audit [--history] [--json out.json]
                                every tracked file; with --history also every blob and commit message on every branch

Fingerprints: salted hashes of T's library (8-word passages, entry titles, lab/vitals readings, medication and
clinician names, lab-report identifiers), built by AirPad `scripts/privacy/make_fingerprints.py` into
~/.airpad-private/fingerprints.json (override: $AIRPAD_FINGERPRINTS). That file never enters a repo.
Output names the path and the KIND of match only — never the matched text. A missing fingerprint file warns loudly
and lets the commit through. Escape hatch for a confirmed false positive: `git commit --no-verify`.
"""
import hashlib, json, os, re, subprocess, sys, unicodedata
from collections import Counter, defaultdict

SHINGLE = 8
STOP = set("""a about above after again against all am an and any are as at be because been before being below
between both but by can could did do does doing down during each few for from further had has have having he her here
hers herself him himself his how i if in into is it its itself just me more most my myself no nor not now of off on
once only or other our ours ourselves out over own same she should so some such than that the their theirs them
themselves then there these they this those through to too under until up very was we were what when where which
while who whom why will with would you your yours yourself yourselves also like get got one really much even""".split())
FP_PATH = os.environ.get("AIRPAD_FINGERPRINTS", os.path.expanduser("~/.airpad-private/fingerprints.json"))

_U = re.compile(r"\\u([0-9a-fA-F]{4})")
_TOK = re.compile(r"[a-z]+|\d+(?:\.\d+)?")

def tokens(text):
    text = _U.sub(lambda m: chr(int(m.group(1), 16)), text).replace("\\n", " ").replace("\\t", " ")
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"(?<=\d),(?=\d{3})", "", re.sub(r"['’‘`]", "", text))
    return _TOK.findall(text)

def h(salt, kind, s):
    return hashlib.sha256(f"{salt}|{kind}|{s}".encode()).hexdigest()[:20]

_PHONE = re.compile(r"\+?\d?\s*\(?\d{3}\)?[\s.\-]*\d{3}[\s.\-]*\d{4}")
_LONGID = re.compile(r"\b\d{6,}\b")
_ICD = re.compile(r"\b[A-TV-Z]\d{2}\.\d{1,4}\b")

class FP:
    def __init__(self, d):
        self.salt = d["salt"]; self.n = d.get("shingle", SHINGLE)
        self.title_lens = d["title_lens"]; self.pair_lens = d.get("pair_lens", [1, 2, 3, 4])
        self.k = {k: set(v) for k, v in d["kinds"].items()}

    def _has(self, kind, s):
        return h(self.salt, kind, s) in self.k.get(kind, ())

    def scan(self, text):
        hits = Counter()
        t = tokens(text)
        for i in range(len(t) - self.n + 1):
            if self._has("passage", " ".join(t[i:i + self.n])): hits["passage"] += 1
        for L in self.title_lens:
            for i in range(len(t) - L + 1):
                if self._has("title", " ".join(t[i:i + L])): hits["title"] += 1
        for j, x in enumerate(t):
            if not x[0].isdigit(): continue
            f = [y for y in t[max(0, j - 6):j] if y not in STOP and not y[0].isdigit()][-5:]
            for e in (len(f), len(f) - 1):
                for L in self.pair_lens:
                    if e - L >= 0 and self._has("pair", " ".join(f[e - L:e]) + " " + x):
                        hits["pair"] += 1; break
        for x in set(t):
            if self._has("med", x): hits["med"] += 1
        for L in (2, 3, 4):
            for i in range(len(t) - L + 1):
                if self._has("provider", " ".join(t[i:i + L])): hits["provider"] += 1
        for m in _PHONE.finditer(text):
            if self._has("number", re.sub(r"\D", "", m.group(0))[-10:]): hits["number"] += 1
        for m in _LONGID.finditer(text):
            if self._has("number", m.group(0)): hits["number"] += 1
        for m in _ICD.finditer(text):
            if self._has("number", m.group(0)): hits["number"] += 1
        return hits

def load():
    try:
        with open(FP_PATH) as f: return FP(json.load(f))
    except FileNotFoundError:
        bar = "!" * 72
        sys.stderr.write(f"\n{bar}\n!! fpscan: NO FINGERPRINT FILE at {FP_PATH}\n!! T's-library guard is OFF for this "
                         f"commit. Rebuild it: AirPad scripts/privacy/make_fingerprints.py\n{bar}\n\n")
        return None

def fmt(hits):
    return ", ".join(f"{k}×{v}" for k, v in sorted(hits.items()))

def git(*a, text=True):
    return subprocess.run(["git", *a], capture_output=True, text=text, check=True).stdout

def staged_additions():
    out = git("diff", "--cached", "--no-color", "--no-ext-diff", "-U0", "--diff-filter=ACMRT", text=False)
    files, cur = defaultdict(list), None
    for raw in out.split(b"\n"):
        line = raw.decode("utf-8", "replace")
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
            if cur: files[cur].append(cur)  # the path itself can carry a title
        elif cur and line.startswith("+"):
            files[cur].append(line[1:])
    return files

def block(rows, what):
    sys.stderr.write(f"\nfpscan: BLOCKED — this {what} matches T's library fingerprints:\n")
    for path, hits in rows: sys.stderr.write(f"  {path}: {fmt(hits)}\n")
    sys.stderr.write("Refer to T's entries by ID or a neutral description, never by quoting them.\n"
                     "(Confirmed false positive only: git commit --no-verify.)\n\n")
    return 1

def cmd_staged(fp):
    rows = [(p, hh) for p, lines in staged_additions().items() if (hh := fp.scan("\n".join(lines)))]
    return block(rows, "commit") if rows else 0

def cmd_msg(fp, path):
    msg = "\n".join(l for l in open(path, encoding="utf-8", errors="replace").read().split("\n") if not l.startswith("#"))
    hh = fp.scan(msg)
    return block([("commit message", hh)], "commit message") if hh else 0

def read_text(b):
    if b"\0" in b[:8000]: return None
    return b.decode("utf-8", "replace")

def cmd_files(fp, paths):
    bad = 0
    for p in paths:
        t = read_text(open(p, "rb").read())
        hh = fp.scan(t) if t is not None else Counter()
        print(f"{'MATCH' if hh else 'clean'} {p}" + (f": {fmt(hh)}" if hh else "")); bad |= bool(hh)
    return int(bad)

def cmd_audit(fp, history, out_json):
    res = {"tree": {}, "history_paths": {}, "commits": [], "messages": [], "blobs_scanned": 0, "blobs_hit": 0}
    for p in git("ls-files", "-z").split("\0"):
        if not p or not os.path.isfile(p) or os.path.getsize(p) > 50_000_000: continue
        t = read_text(open(p, "rb").read())
        if t is not None and (hh := fp.scan(t)): res["tree"][p] = dict(hh)
    if history:
        paths = defaultdict(set)
        for line in git("rev-list", "--all", "--objects").split("\n"):
            if " " in line: sha, p = line.split(" ", 1); paths[sha].add(p)
        chk = subprocess.run(["git", "cat-file", "--batch-check"], input="\n".join(paths), capture_output=True,
                             text=True, check=True).stdout.split("\n")
        blobs = [l.split()[0] for l in chk if l.endswith(tuple("0123456789")) and " blob " in l
                 and int(l.split()[2]) <= 50_000_000]
        proc = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        proc.stdin.write(("\n".join(blobs) + "\n").encode()); proc.stdin.close()
        hit_blobs, per_path = set(), defaultdict(Counter)
        for _ in blobs:
            sha, _, size = proc.stdout.readline().decode().split()
            data = proc.stdout.read(int(size)); proc.stdout.read(1)
            res["blobs_scanned"] += 1
            t = read_text(data)
            if t is None: continue
            hh = fp.scan(t)
            if hh:
                hit_blobs.add(sha)
                for p in paths[sha]: per_path[p].update(hh); per_path[p]["versions"] += 1
        proc.wait()
        res["blobs_hit"] = len(hit_blobs)
        res["history_paths"] = {p: dict(c) for p, c in sorted(per_path.items())}
        commits, cur = set(), None
        for line in git("log", "--all", "--raw", "--no-abbrev", "--no-renames", "--format=C%H").split("\n"):
            if line.startswith("C"): cur = line[1:]
            elif line.startswith(":") and line.split()[3] in hit_blobs: commits.add(cur)
        res["commits"] = sorted(commits)
        for rec in git("log", "--all", "--format=%H%x00%B%x01").split("\x01"):
            if "\0" in rec:
                sha, body = rec.strip("\n").split("\0", 1)
                if hh := fp.scan(body): res["messages"].append({"commit": sha, **dict(hh)})
    if out_json:
        with open(out_json, "w") as f: json.dump(res, f, indent=1)
    print(f"tree: {len(res['tree'])} file(s) match" + (f" · history: {res['blobs_hit']}/{res['blobs_scanned']} blobs, "
          f"{len(res['history_paths'])} path(s), {len(res['commits'])} commit(s), {len(res['messages'])} message(s)"
          if history else ""))
    for p, hh in res["tree"].items(): print(f"  tree {p}: {fmt(Counter(hh))}")
    return 0

def main(argv):
    if not argv: print(__doc__); return 2
    fp = load()
    if fp is None: return 0
    if argv[0] == "staged": return cmd_staged(fp)
    if argv[0] == "msg": return cmd_msg(fp, argv[1])
    if argv[0] == "files": return cmd_files(fp, argv[1:])
    if argv[0] == "audit":
        out = argv[argv.index("--json") + 1] if "--json" in argv else None
        return cmd_audit(fp, "--history" in argv, out)
    print(__doc__); return 2

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
