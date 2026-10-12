#!/usr/bin/env python3
"""live-6 (3) — build T's library fingerprint file for the pre-commit guard (`.githooks/fpscan.py`).

    make_fingerprints.py [--fixture ~/Developer/fixtures/tom-corpus-2026-09-21] [--out ~/.airpad-private/fingerprints.json]

Reads the corpus fixture (Sample Library entries excluded) and writes SALTED HASHES only — the output holds no
readable corpus text, and this script prints counts only. The output must live outside every repo and outside
iCloud (default `~/.airpad-private/`, mode 600); it is never committed.

Kinds (same set as the live-5 audit, plus titles):
  passage  every 8-word run of an entry's text (items, extracted blocks, title, summaries)
  title    entry titles of >= 2 words (product-copy titles excluded)
  pair     lab / vitals readings: an analyte or vitals label followed by its value ("LDL 123", "Resting HR: 52")
  med      medication names (a word followed by a dose, or a drug-name suffix; dictionary words excluded)
  provider clinician names ("Dr Name", "Physician: First Last")
  number   identifiers from the lab report header (phone numbers, ids of 6+ digits)
"""
import argparse, hashlib, json, os, re, secrets, sys, time
from glob import glob

sys.dont_write_bytecode = True  # no __pycache__ inside .githooks
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".githooks"))
from fpscan import tokens, h, SHINGLE, STOP  # noqa: E402  (the guard's own normaliser, so both sides agree)

ap = argparse.ArgumentParser()
ap.add_argument("--fixture", default=os.path.expanduser("~/Developer/fixtures/tom-corpus-2026-09-21"))
ap.add_argument("--out", default=os.path.expanduser("~/.airpad-private/fingerprints.json"))
a = ap.parse_args()

out = os.path.abspath(a.out)
for bad in (os.path.expanduser("~/Developer"), os.path.expanduser("~/Library/Mobile Documents"),
            os.path.expanduser("~/Desktop"), os.path.expanduser("~/Documents")):
    if out.startswith(bad + os.sep):
        sys.exit(f"refusing to write fingerprints under {bad} (repos / iCloud)")

sample = set(json.load(open(os.path.join(a.fixture, "sample_library.json")))["nodeIDs"])
# The two AirPad product-copy notes: their text is product copy that also lives in the repos (live-5 6b).
PRODUCT_TITLES = {"project airpad", "airpad marketing"}
LAB_LINE = re.compile(r"^([A-Za-z][A-Za-z0-9 ,/()%.\-]{0,48}?)\s+[<>]?(\d+(?:\.\d+)?)\s+(?:[<>]?\d+(?:\.\d+)?\s*-\s*\d+(?:\.\d+)?|[<>]\s*\d+(?:\.\d+)?)",)
LABEL_VALUE = re.compile(r"([A-Za-z][A-Za-z %/()\-]{1,40}?)\s*[:=]\s*(?:[*~\\]*\s*)?[<>~]?(\d+(?:[.,]\d+)?)")
VITALS = re.compile(r"weight|resting|heart|hr\b|hrv|pulse|bmi|vo2|body fat|systolic|diastolic|blood|pressure|"
                    r"glucose|a1c|cholesterol|ldl|hdl|triglycer|pace|cadence|power|ftp|zone|threshold|spo2|"
                    r"temperature|calorie|sleep|steps|mileage|distance|bpm|max", re.I)
DOSE = re.compile(r"\b([A-Za-z][A-Za-z\-]{3,})\s+\(?\d+(?:\.\d+)?\s?(?:mg|mcg|µg|ml|iu)\b", re.I)
DRUG_SUFFIX = re.compile(r"\b([A-Za-z]{4,}(?:pril|olol|statin|sartan|prazole|azole|dipine|xetine|oxetine|triptyline|"
                         r"zepam|azepam|zolam|codone|morphone|afil|tadine|gliptin|formin|cycline|cillin|mycin|"
                         r"floxacin|thiazide|semide|lukast|tropium|terol|olone|asone|pramine|peridone|apine|"
                         r"etine|fenac|profen|caine|vudine|navir|zodone|xapine|lamide|tamine|phetamine|"
                         r"methylphenidate|trigine|tiapine|barbital))\b", re.I)
PROVIDER = [re.compile(r"\bDr\.?\s+([A-Z][a-zA-Z\-']+(?:\s+[A-Z][a-zA-Z\-']+)?)"),
            re.compile(r"(?:Physician|Provider|Ordering|Doctor|Clinician|Therapist|Psychiatrist)\s*(?:Name)?\s*:\s*"
                       r"([A-Z][a-zA-Z\-']+(?:,?\s+[A-Z][a-zA-Z\-'.]+){1,2})")]
# lab report only: signatures "First Last, MD", sign-offs "Last, First 01/02/2025", and provider table rows
CREDENTIAL = re.compile(r"([A-Z][a-z'\-]+(?:\s[A-Z]\.?)?\s[A-Z][a-z'\-]+),?\s+(?:MD|DO|NP|PA-C|PA|APRN|FNP|RN|PhD|LCSW|LPC)\b")
SIGNOFF = re.compile(r"^([A-Z][a-z'\-]+),\s([A-Z][a-z'\-]+)\s+\d{1,2}/\d{1,2}/\d{4}")
CAPS_BIGRAM = re.compile(r"(?=\b([A-Z][a-z'\-]+\s[A-Z][a-z'\-]+)\b)")
# lab report only: any "Label [:] value" line (results, vitals); a leading date is dropped; a value that is part of a
# date/time is not a reading; a lone generic word is not a label
LAB_ANY = re.compile(r"^([A-Za-z][A-Za-z ,()/\-]{0,40}?)(?:\s*:\s*|\s+)[<>]?(\d+(?:\.\d+)?)(?![/:.]?\d)")
VALUE_FIRST = re.compile(r"^[<>]?(\d+(?:\.\d+)?)\s+[<>]?\d+(?:\.\d+)?\s*-\s*\d+(?:\.\d+)?")
GENERIC = {"page", "step", "version", "item", "line", "part", "section", "no", "number", "id", "total", "of", "and",
           "suite", "ste", "fax", "phone", "tel", "zip", "box", "room", "floor", "unit", "age", "visit", "order"}
ICD = re.compile(r"\b[A-TV-Z]\d{2}\.\d{1,4}\b")
PHONE = re.compile(r"\+?\d?\s*\(?\d{3}\)?[\s.\-]*\d{3}[\s.\-]*\d{4}")
LONGID = re.compile(r"\b\d{6,}\b")
DICT = set(w.strip().lower() for w in open("/usr/share/dict/words")) if os.path.exists("/usr/share/dict/words") else set()

# Anything that also occurs in the Sample Library (which the app ships) is not a fingerprint of T's library.
sample_streams = []
for p in glob(os.path.join(a.fixture, "nodes", "*", "node.json")):
    d = json.load(open(p))
    if d.get("id") not in sample: continue
    parts = [d.get("title") or "", d.get("summary") or "", d.get("substrate_summary") or ""]
    parts += [it["content"] for it in d.get("items", []) if isinstance(it.get("content"), str)]
    bp = os.path.join(os.path.dirname(p), "blocks.json")
    if os.path.exists(bp): parts += [b.get("text", "") for b in json.load(open(bp)).get("blocks", [])]
    sample_streams += [" " + " ".join(tokens(x)) + " " for x in parts]
sample_blob = "".join(sample_streams)
sample_words = set(sample_blob.split())
sample_shingles = set()
for st in sample_streams:
    t = st.split()
    sample_shingles.update(" ".join(t[i:i + SHINGLE]) for i in range(len(t) - SHINGLE + 1))

salt = secrets.token_hex(16)
fp = {k: set() for k in ("passage", "title", "pair", "med", "provider", "number")}
title_lens, pair_lens = set(), set()
n_entries = 0

def entry_text(d, dirpath):
    parts = [d.get("title") or "", d.get("summary") or "", d.get("substrate_summary") or ""]
    for it in d.get("items", []):
        c = it.get("content")
        if isinstance(c, str): parts.append(c)
    bp = os.path.join(dirpath, "blocks.json")
    if os.path.exists(bp):
        parts += [b.get("text", "") for b in json.load(open(bp)).get("blocks", [])]
    return parts

def add_pair(label, value, lab_result):
    lt = [t for t in tokens(label) if t not in STOP and not t[0].isdigit()]
    v = value.replace(",", "")
    if re.fullmatch(r"\d", v): return  # a one-digit reading ("take 1", "gap 9") is too generic to fingerprint
    # every contiguous run of the label's words, so "Resting HR" also fingerprints "HR 52"
    for i in range(len(lt)):
        for j in range(i + 1, min(len(lt), i + 4) + 1):
            run = lt[i:j]
            # a lone common word ("max 180", "weight 400") is too generic, except a lab result's analyte
            # (and a common word cut out of a longer label, "content" from "...hemoglobin content", never)
            if len(run) == 1 and (len(run[0]) < 2 or (run[0] in DICT and (not lab_result or len(lt) > 1))): continue
            fp["pair"].add(h(salt, "pair", " ".join(run) + " " + v)); pair_lens.add(len(run))

for p in sorted(glob(os.path.join(a.fixture, "nodes", "*", "node.json"))):
    d = json.load(open(p))
    if d.get("id") in sample: continue
    n_entries += 1
    title_t = tokens(d.get("title") or "")
    product = " ".join(title_t) in PRODUCT_TITLES
    if len(title_t) >= 2 and len("".join(title_t)) >= 8 and not product and f" {' '.join(title_t)} " not in sample_blob:
        fp["title"].add(h(salt, "title", " ".join(title_t))); title_lens.add(len(title_t))
    parts = entry_text(d, os.path.dirname(p))
    if not product:
        for part in parts:
            t = tokens(part)
            for i in range(len(t) - SHINGLE + 1):
                w = t[i:i + SHINGLE]
                if sum(1 for x in w if x not in STOP) >= 3 and " ".join(w) not in sample_shingles:
                    fp["passage"].add(h(salt, "passage", " ".join(w)))
    blob = "\n".join(parts)
    lab = sum(1 for _ in re.finditer(r"mg/dL|mmol/L|g/dL|U/L|x10E3|mmHg", blob, re.I)) >= 3
    for line in blob.split("\n"):
        s = re.sub(r"[*_`#>]+", " ", line).strip()
        m = LAB_LINE.match(s) if lab else None
        if m: add_pair(m.group(1), m.group(2), True)
        for m in LABEL_VALUE.finditer(s):
            if re.match(r"[/:]\d", s[m.end():m.end() + 2]): continue  # a date or a time, not a reading
            if VITALS.search(m.group(1)): add_pair(m.group(1), m.group(2), False)
    for m in list(DOSE.finditer(blob)) + list(DRUG_SUFFIX.finditer(blob)):
        for w in tokens(m.group(1)):
            if len(w) >= 5 and w not in DICT and w not in STOP and w not in sample_words:
                fp["med"].add(h(salt, "med", w))
    for rx in PROVIDER:
        for m in rx.finditer(blob):
            t = tokens(m.group(1))
            if t and not all(x in DICT for x in t):
                if len(t) >= 2: fp["provider"].add(h(salt, "provider", " ".join(t)))
                if rx is PROVIDER[0]: fp["provider"].add(h(salt, "provider", "dr " + " ".join(t)))
    if lab:
        lines = [re.sub(r"[*_`#>]+", " ", l).strip() for l in blob.split("\n")]
        prev = ""
        for s in lines:
            if not s: continue
            s2 = re.sub(r"^\d{1,2}/\d{1,2}/\d{2,4}\s+", "", s)
            m = LAB_ANY.match(s2)
            if m:
                lt = [x for x in tokens(m.group(1)) if x not in STOP]
                # a lone common word ("Height 72") counts only on a result line with a reference range (LAB_LINE)
                if lt and not (len(lt) == 1 and lt[0] in GENERIC): add_pair(m.group(1), m.group(2), False)
            m = VALUE_FIRST.match(s)
            if m and re.match(r"^[A-Za-z][A-Za-z ,()/\-]{1,40}$", prev): add_pair(prev, m.group(1), True)
            prev = s
            for m in CREDENTIAL.finditer(s):
                fp["provider"].add(h(salt, "provider", " ".join(tokens(m.group(1)))))
            m = SIGNOFF.match(s)
            if m:
                fp["provider"].add(h(salt, "provider", " ".join(tokens(m.group(1) + " " + m.group(2)))))
                fp["provider"].add(h(salt, "provider", " ".join(tokens(m.group(2) + " " + m.group(1)))))
            if "rovider" in s:
                for m in CAPS_BIGRAM.finditer(s):
                    t = tokens(m.group(1))
                    if "provider" not in t and not all(x in DICT for x in t):
                        fp["provider"].add(h(salt, "provider", " ".join(t)))
        for m in ICD.finditer(blob):
            fp["number"].add(h(salt, "number", m.group(0)))
        for m in PHONE.finditer(blob):
            fp["number"].add(h(salt, "number", re.sub(r"\D", "", m.group(0))[-10:]))
        for m in LONGID.finditer(blob):
            fp["number"].add(h(salt, "number", m.group(0)))

# a reading the scanner would also find in Sample Library text ("CO2 24" in a sample note) is dropped
for st in sample_streams:
    t = st.split()
    for j, x in enumerate(t):
        if not x[0].isdigit(): continue
        f = [y for y in t[max(0, j - 6):j] if y not in STOP and not y[0].isdigit()][-5:]
        for e in (len(f), len(f) - 1):
            for L in range(1, 5):
                if e - L >= 0: fp["pair"].discard(h(salt, "pair", " ".join(f[e - L:e]) + " " + x))

os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
os.chmod(os.path.dirname(out), 0o700)
doc = {"version": 1, "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "fixture": os.path.basename(a.fixture.rstrip("/")),
       "entries": n_entries, "salt": salt, "shingle": SHINGLE, "title_lens": sorted(title_lens),
       "pair_lens": sorted(pair_lens), "kinds": {k: sorted(v) for k, v in fp.items()}}
tmp = out + ".tmp"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f: json.dump(doc, f)
os.replace(tmp, out)
print(f"wrote {out} · entries {n_entries} · " + " · ".join(f"{k} {len(v)}" for k, v in fp.items()))
