#!/usr/bin/env python3
"""Sweep 2b · 3.1 — the suite's graders on hand-made result rows (no app, no model, no Simulator, no fixture).

  python3 -B scripts/librarian/suite/tests/test_suite.py

Every guarantee gets a passing row and a failing row; then the planted-error check, pass^k over wordings, the coverage
columns, A8, the private path (no text survives) and the data files (wordings, overlay, the relevance format).
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import suite  # noqa: E402

P = "BE7C0000-0000-4000-8000-"
BASE = len(json.loads((suite.BENCHMARK / "notes.json").read_text())["notes"])
PLANTED = [n["key"] for n in json.loads((suite.HERE / "planted-notes.json").read_text())["notes"]]


def nid(key):
    """The seeded ID of a planted note: base notes first, then the overlay (LibrarianBench.seedNotes numbering)."""
    return f"{P}{BASE + PLANTED.index(key) + 1:012d}"


OTHER = "9E9F1000-0000-4000-8000-000000000003"   # a perf-library entry (word salad, never supports anything)
TITLES = {nid(k): t for k, t in ((n["key"], n["title"]) for n in json.loads((suite.HERE / "planted-notes.json").read_text())["notes"])}


def row(id, answer, *, mode="library", route="server", plan="read", decision=None, sent=(), chips=(), inline=(),
        title_fallback=False, line=False, tokens=None, chars=None, num_ctx=20480, served=None, model=True):
    rec = {"planMode": plan, "decision": decision or {"read": "read(dominance)", "survey": "survey", "empty": "empty(bar)"}.get(plan, plan),
           "sent": [{"node": n, "kind": k} for n, k in sent],
           "cited": [{"node": n, "inline": n in inline} for n, _ in chips],
           "answer": {"titleFallback": title_fallback}}
    if model:
        rec["request"] = {"systemChars": chars or 0, "turnChars": 0, "historyChars": 0, "numCtx": num_ctx}
        rec["tokens"] = {"prompt": tokens}
        rec["servedNumCtx"] = served or num_ctx
    return {"id": id, "mode": mode, "route": route, "answer": answer, "chips": [{"nodeID": n, "index": i + 1} for i, (n, _) in enumerate(chips)],
            "noMatchLine": line, "record": rec}


def results(rows, route="server"):
    return {"route": route, "model": "test", "titles": TITLES, "rows": rows}


def grade(rows, setname="planted", private=False, route="server"):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "results.json"; p.write_text(json.dumps(results(rows, route)))
        g = suite.grade_run(setname, p, private=private)
    return {r["id"]: r for r in g["rows"]}, g


def gate(r, k):
    v = r["guarantees"][k]
    return None if not v["applies"] else v["ok"]


class Guarantees(unittest.TestCase):
    # G1 — nothing sent, the model must not describe an entry
    def test_g1_pass_and_fail(self):
        ok = row("PH6", "I couldn't find a close match in your library. Insulin doses are set by a clinician.", plan="empty", line=True, tokens=100, chars=400)
        bad = row("PH6", "You have a note titled 'Insulin log' that says you take 12 units.", plan="empty", line=True, tokens=100, chars=400)
        named = row("PH6", "Nothing on insulin, but see Migraine diary – October for your medicines.", plan="empty", line=True, tokens=100, chars=400)
        for r, want in ((ok, True), (bad, False), (named, False)):
            g, _ = grade([r]); self.assertEqual(gate(g["PH6"], "G1"), want, r["answer"])
        g, _ = grade([row("PH3", "You have a note titled Therapy – session 6.", sent=[(nid("therapy"), "read")], chips=[(nid("therapy"), 1)], inline=[nid("therapy")], tokens=300, chars=1200)])
        self.assertIsNone(gate(g["PH3"], "G1"), "not applicable when library text was sent")

    # G2 — an evidence case never goes to no match
    def test_g2_pass_and_fail(self):
        good = row("PH3", "Box breathing [1].", sent=[(nid("therapy"), "read")], chips=[(nid("therapy"), 1)], inline=[nid("therapy")], tokens=300, chars=1200)
        empty = row("PH3", "No close match. Box breathing is a technique…", plan="empty", line=True, tokens=90, chars=360)
        subject = row("PH3", "I found nothing about that.", plan="none(subject)", model=False)
        self.assertTrue(gate(grade([good])[0]["PH3"], "G2"))
        self.assertFalse(gate(grade([empty])[0]["PH3"], "G2"))
        self.assertFalse(gate(grade([subject])[0]["PH3"], "G2"))
        self.assertIsNone(gate(grade([row("PH6", "x", plan="empty", line=True, tokens=9, chars=36)])[0]["PH6"], "G2"))

    # G3 — no chip by rule on a surveyed entry
    def test_g3_pass_and_fail(self):
        th = nid("therapy")
        by_rule = row("PH3", "Box breathing.", plan="survey", sent=[(th, "passage")], chips=[(th, 1)], tokens=300, chars=1200)
        inline = row("PH3", "Box breathing [1].", plan="survey", sent=[(th, "passage")], chips=[(th, 1)], inline=[th], tokens=300, chars=1200)
        named = row("PH3", "Box breathing, from Therapy – session 6.", plan="survey", sent=[(th, "card")], chips=[(th, 1)], title_fallback=True, tokens=300, chars=1200)
        read = row("PH3", "Box breathing.", sent=[(th, "read")], chips=[(th, 1)], tokens=300, chars=1200)
        never = row("PH3", "Box breathing [1].", plan="survey", sent=[(OTHER, "passage")], chips=[(th, 1)], inline=[th], tokens=300, chars=1200)
        for r, want in ((by_rule, False), (inline, True), (named, True), (read, True), (never, False)):
            self.assertEqual(gate(grade([r])[0]["PH3"], "G3"), want)
        self.assertIn("never sent", grade([never])[0]["PH3"]["guarantees"]["G3"]["detail"])

    # G4 — the no-match path shows the app's line and no chip; the line never sits over notes
    def test_g4_pass_and_fail(self):
        ok = row("PH6", "Insulin doses vary.", plan="empty", line=True, tokens=90, chars=360)
        no_line = row("PH6", "Insulin doses vary.", plan="empty", line=False, tokens=90, chars=360)
        chip = row("PH6", "Insulin doses vary.", plan="empty", line=True, chips=[(OTHER, 1)], tokens=90, chars=360)
        over_notes = row("PH3", "Box breathing [1].", sent=[(nid("therapy"), "read")], chips=[(nid("therapy"), 1)], inline=[nid("therapy")], line=True, tokens=300, chars=1200)
        self.assertTrue(gate(grade([ok])[0]["PH6"], "G4"))
        self.assertFalse(gate(grade([no_line])[0]["PH6"], "G4"))
        self.assertFalse(gate(grade([chip])[0]["PH6"], "G4"))
        self.assertFalse(gate(grade([over_notes])[0]["PH3"], "G4"))
        self.assertEqual(suite.NO_MATCH_LINE, "This answer is from the model's general knowledge, not your notes.")

    # G5 — A8: the server counted what was sent
    def test_g5_pass_and_fail(self):
        base = dict(sent=[(nid("therapy"), "read")], chips=[(nid("therapy"), 1)], inline=[nid("therapy")])
        ok = row("PH3", "Box breathing [1].", tokens=1000, chars=4000, **base)
        cut = row("PH3", "Box breathing [1].", tokens=2048, chars=24000, **base)        # 11.7 chars per token: a front cut
        full = row("PH3", "Box breathing [1].", tokens=4096, chars=17000, num_ctx=4096, **base)
        smaller = row("PH3", "Box breathing [1].", tokens=1000, chars=4000, served=4096, **base)
        self.assertTrue(gate(grade([ok])[0]["PH3"], "G5"))
        self.assertEqual(grade([cut])[0]["PH3"]["guarantees"]["G5"]["detail"], "shortfall")
        self.assertEqual(grade([full])[0]["PH3"]["guarantees"]["G5"]["detail"], "window-full")
        self.assertEqual(grade([smaller])[0]["PH3"]["guarantees"]["G5"]["detail"], "served-window-smaller")
        apple = dict(ok, route="apple")
        self.assertIsNone(gate(grade([apple], route="apple")[0]["PH3"], "G5"))

    def test_broken_guarantee_fails_the_case(self):
        th = nid("therapy")
        r = row("PH3", "Box breathing.", plan="survey", sent=[(th, "passage")], chips=[(th, 1)], tokens=300, chars=1200)
        g, _ = grade([r])
        self.assertTrue(g["PH3"]["quality"]); self.assertFalse(g["PH3"]["pass"]); self.assertEqual(g["PH3"]["broken"], ["G3"])


class PlantedError(unittest.TestCase):
    def test_flat_vs_attributed(self):
        case = {"plantedError": ["bats are blind"]}
        self.assertTrue(suite.planted_error(case, "Bats are blind, so they use echolocation."))
        self.assertIsNone(suite.planted_error(case, "Your note says bats are blind. That's a myth: bats can see."))
        self.assertIsNone(suite.planted_error(case, "The idea that bats are blind is a misconception."))
        self.assertIsNone(suite.planted_error(case, "No, bats are blind is not right; they see fine."))
        self.assertIsNone(suite.planted_error({}, "Bats are blind."))
        fish = {"plantedError": ["three-second memory"]}
        self.assertTrue(suite.planted_error(fish, "Your goldfish only have a three-second memory."), "'your' alone is not attribution")
        self.assertTrue(suite.planted_error(fish, "Goldfish only have a three-second memory, so they won't miss the tank."))
        self.assertTrue(suite.planted_error({"plantedError": ["glass is a liquid"]}, "Actually, glass is a liquid."))
        self.assertIsNone(suite.planted_error(fish, "Your note says goldfish have a three-second memory; studies show months."))

    def test_graded_on_a_wrong_gk_case(self):
        b = nid("bats")
        good = row("PW1", "Your note says bats are blind [1], but that's a myth: bats can see.", sent=[(b, "read")], chips=[(b, 1)], inline=[b], tokens=300, chars=1200)
        bad = row("PW1", "Bats are blind and rely on echolocation [1]. You noted nine pipistrelles.", sent=[(b, "read")], chips=[(b, 1)], inline=[b], tokens=300, chars=1200)
        self.assertTrue(grade([good])[0]["PW1"]["pass"])
        g = grade([bad])[0]["PW1"]
        self.assertFalse(g["pass"]); self.assertTrue(any(f.startswith("planted-error") for f in g["fails"]))

    def test_conflict_between_notes(self):
        a, b = nid("storage-visit"), nid("storage-invoice")
        both = row("PK1", "Your notes differ: B14 in one [1], B41 on the invoice [2].", sent=[(a, "read"), (b, "read")], chips=[(a, 1), (b, 2)], inline=[a, b], tokens=300, chars=1200)
        picks = row("PK1", "Your unit is B14 [1].", sent=[(a, "read"), (b, "read")], chips=[(a, 1)], inline=[a], tokens=300, chars=1200)
        self.assertTrue(grade([both])[0]["PK1"]["pass"])
        self.assertFalse(grade([picks])[0]["PK1"]["pass"])

    def test_sensitive_leak(self):
        leak = row("PH4", "Bring snacks. If panic starts, try box breathing.", plan="empty", line=True, tokens=90, chars=360)
        clean = row("PH4", "Bring snacks, water and a book.", plan="empty", line=True, tokens=90, chars=360)
        self.assertFalse(grade([leak])[0]["PH4"]["pass"])
        self.assertTrue(grade([clean])[0]["PH4"]["pass"])


class Report(unittest.TestCase):
    def build(self, root, per_wording, setname="planted", log_lines=()):
        for w, rows in per_wording.items():
            d = Path(root) / setname / "qwen354b" / f"w{w}-r1"; d.mkdir(parents=True)
            (d / "results.json").write_text(json.dumps(results(rows)))
            (d / "graded.json").write_text(json.dumps(suite.grade_run(setname, d / "results.json")))
        log = Path(root).parent / "ollama.log"; log.write_text("\n".join(log_lines))
        return log

    def test_pass_k_coverage_and_gate(self):
        th, b = nid("therapy"), nid("bats")
        good = lambda: row("PH3", "Box breathing [1].", sent=[(th, "read")], chips=[(th, 1)], inline=[th], tokens=300, chars=1200)
        insulin = lambda: row("PH6", "Doses vary by person.", plan="empty", line=True, tokens=90, chars=360)
        bats = lambda: row("PW1", "Your note says bats are blind [1], but that's a myth: they can see.", sent=[(b, "read")], chips=[(b, 1)], inline=[b], tokens=300, chars=1200)
        w5_bad = row("PH3", "Box breathing.", plan="survey", sent=[(th, "passage")], chips=[(th, 1)], tokens=300, chars=1200)
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "runs"
            per = {w: [good(), insulin(), bats()] for w in range(1, 5)}
            per[5] = [w5_bad, insulin(), bats()]
            log = self.build(root, per, log_lines=["level=WARN msg=\"truncating input prompt\" limit=2048"])
            text, js = suite.report(root, ollama_log=log)
            s = js["runs"]["planted/qwen354b"]
            self.assertEqual(s["cases"], 3); self.assertEqual(s["passK"], 2, "PH3 failed one wording of five")
            self.assertEqual(s["perCase"]["PH3"], [4, 5])
            self.assertEqual(s["byWording"][5], [2, 3])
            self.assertEqual(s["gate"]["G3"], [1, 10])   # PH3 and PW1 both carry chips
            c = s["coverage"]
            self.assertEqual((c["supAns"], c["sup"]), (10, 10))
            self.assertEqual((c["unsNone"], c["unsTold"], c["unsNoChip"], c["uns"]), (5, 5, 5, 5))
            self.assertEqual((c["goodChips"], c["chips"]), (10, 10))
            self.assertEqual((c["plantedOK"], c["planted"]), (5, 5))
            self.assertEqual(js["truncationLines"], 1)
            self.assertEqual(js["gateBreaks"], 2)
            self.assertIn("**Gate: FAIL**", text)
            self.assertIn("PH3 w5 r1 G3 (chip by rule on a surveyed entry)", text)

    def test_all_clean_gate_passes(self):
        th = nid("therapy")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "runs"
            log = self.build(root, {w: [row("PH3", "Box breathing [1].", sent=[(th, "read")], chips=[(th, 1)], inline=[th], tokens=300, chars=1200)] for w in (1, 2)})
            line = Path(d) / "line-check.txt"; line.write_text("ok · verbatim")
            text, js = suite.report(root, ollama_log=log, line_check=line)
            self.assertEqual(js["gateBreaks"], 0); self.assertIn("**Gate: PASS**", text)
            line.write_text("MISSING")
            self.assertEqual(suite.report(root, ollama_log=log, line_check=line)[1]["gateBreaks"], 1)


class Private(unittest.TestCase):
    SECRET = "Zanzibar quince ledger"   # stands in for a user's words

    def test_graded_and_scrubbed_carry_no_text(self):
        r = row("PH6", f"You have a note titled {self.SECRET} about it.", plan="empty", line=False, tokens=90, chars=360)
        r["receipt"] = f"Read *{self.SECRET}* in full"; r["packet"] = self.SECRET
        r["chips"] = [{"nodeID": OTHER, "index": 1, "title": self.SECRET}]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "results.json"; p.write_text(json.dumps(results([r])))
            log = Path(d) / "app.log"
            log.write_text(f"[LibrarianBench] TURN PH6 END 1.0s decision=empty(bar) chips=1 answerChars=40\nsome line with {self.SECRET}\n")
            g = suite.grade_run("planted", p, private=True)
            self.assertNotIn(self.SECRET.lower(), json.dumps(g).lower())
            self.assertTrue(g["rows"][0]["broken"])           # the breaks are still counted, by kind
            suite.scrub(p, log)
            self.assertNotIn(self.SECRET, p.read_text()); self.assertNotIn(self.SECRET, log.read_text())
            self.assertIn("TURN PH6 END", log.read_text())


class DataFiles(unittest.TestCase):
    def test_check_is_clean(self):
        problems, n = suite.check()
        self.assertEqual(problems, []); self.assertGreaterEqual(n, 5 * (48 + 33 + 15))

    def test_expand_keeps_ids_and_chats(self):
        with tempfile.TemporaryDirectory() as d:
            made = suite.expand(d, ("bench",))
            self.assertEqual(len(made), 5)
            orig = json.loads(suite.CASES["bench"].read_text())
            w3 = json.loads((Path(d) / "bench-w3.json").read_text())
            self.assertEqual([[t["id"] for t in c["turns"]] for c in orig["chats"]], [[t["id"] for t in c["turns"]] for c in w3["chats"]])
            self.assertEqual(w3["chats"][0]["turns"][0]["question"], suite.wordings()["bench"]["F1"][2])
            self.assertEqual(w3["chats"][0]["turns"][0]["facts"], orig["chats"][0]["turns"][0]["facts"])

    def test_overlay_keeps_base_ids(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "o.json"; suite.overlay(p)
            notes = json.loads(p.read_text())["notes"]
            base = json.loads((suite.BENCHMARK / "notes.json").read_text())["notes"]
            self.assertEqual(notes[:len(base)], base)
            self.assertEqual([n["key"] for n in notes[len(base):]], PLANTED)

    def test_relevance_format_in_sync(self):
        w = suite.wordings()
        for lib in ("bench", "sample"):
            d = json.loads((suite.HERE / f"wordings-{lib}.json").read_text())["turns"]
            self.assertEqual(d, {i: v[1:] for i, v in w[lib].items()}, f"run suite.py export-wordings ({lib})")


if __name__ == "__main__":
    unittest.main(verbosity=1)
