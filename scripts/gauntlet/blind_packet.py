#!/usr/bin/env python3
"""CH-A test 5 — the BLIND synthesis packet: `blind_packet.py <cha-store root> <out dir> [S1,S2,S3,S4]`

For each synthesis question, collects every surviving arm × Thinking answer (store pre-screen), strips anything that
names a model, shuffles INDEPENDENTLY per question (SystemRandom — not reproducible, so the key file is the only
mapping), labels A/B/C…, and writes:
  <out>/packet.md         — what T reads: question, then each lettered answer + its sources (titles only)
  <out>/KEY-SEALED.md     — letter → arm/Thinking/model/digest, per question. Do NOT open before T has ranked.
Thinking traces are never included (the answer only, as T would see it)."""
import glob, json, os, random, re, sys

root, out = sys.argv[1], sys.argv[2]
qs = (sys.argv[3] if len(sys.argv) > 3 else "S1,S2,S3,S4").split(",")
here = os.path.dirname(os.path.abspath(__file__))
questions = {c["id"]: c["question"] for ch in json.load(open(os.path.join(here, "cases.json")))["chats"] for c in ch["cases"]}
MODEL_WORDS = re.compile(r"\b(?:qwen\d?(?:\.\d)?|gemma|llama|mistral|deepseek|claude|gpt|instruct|thinking model|as an ai(?: language model)?)\b", re.I)
answers = {q: [] for q in qs}
for arm in sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))):
    for mode in ("off", "on"):
        pd = os.path.join(root, arm, mode)
        if not os.path.exists(os.path.join(pd, "store-rows.json")):
            continue
        v = json.load(open(os.path.join(pd, "versions.json")))
        for r in json.load(open(os.path.join(pd, "store-rows.json")))["rows"]:
            if r["case"] in answers:
                t = json.load(open(os.path.join(pd, f"turn-{r['seq']:03d}.json")))
                text = t.get("finalText") or ""
                masked = MODEL_WORDS.sub("[model]", text)
                answers[r["case"]].append(dict(arm=arm, thinking=mode, model=v.get("model"), digest=(v.get("digest") or "")[:12],
                                               text=masked, masked=masked != text,
                                               sources=[c.get("title", "") for c in (t.get("citations") or [])]))
os.makedirs(out, exist_ok=True)
rng = random.SystemRandom()
P = ["# CH-A test 5 — blind synthesis ranking", "",
     "_For T. Each question's answers come from different model set-ups, with the order shuffled separately for each question. "
     "Model names are removed; the Thinking traces are not shown. Rank the answers for each question (best first), "
     "and say why in a line if you like. The key is in a separate sealed file — Companion opens it only after you've ranked._", ""]
K = ["# CH-A test 5 — KEY (SEALED — do not open until T has ranked)", ""]
for q in qs:
    items = answers[q][:]
    rng.shuffle(items)
    P += [f"## {q} — “{questions.get(q, '')}”", ""]
    K += [f"## {q}", "", "| letter | arm | Thinking | model | digest |", "|---|---|---|---|---|"]
    for i, a in enumerate(items):
        L = chr(65 + i)
        P += [f"### Answer {L}", "", "\n".join("> " + ln if ln.strip() else ">" for ln in a["text"].strip().splitlines()), "",
              f"_Sources shown: {', '.join(a['sources']) or 'none'}_", ""]
        K.append(f"| {L} | {a['arm']} | {a['thinking']} | {a['model']} | {a['digest']} |")
    P += ["**Your ranking (best → worst):** ", "", "---", ""]
    K.append("")
open(os.path.join(out, "packet.md"), "w").write("\n".join(P))
open(os.path.join(out, "KEY-SEALED.md"), "w").write("\n".join(K))
print(f"packet: {sum(len(v) for v in answers.values())} answers over {len(qs)} questions; masked model words in "
      f"{sum(a['masked'] for v in answers.values() for a in v)}")
