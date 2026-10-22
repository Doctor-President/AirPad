#!/usr/bin/env python3
# live-28 (1) — a FAKE Ollama for the runaway rows: the real app → a scratch Host from source (--ollama 127.0.0.1:<port>)
# → this. Synthetic text only. The question picks the behaviour:
#   "presidents"       loop    — a preamble, a table header, 15 rows, then ONE row forever (what temperature 0 did)
#   "every lighthouse" unique  — a new row every few tokens, forever: only num_predict (done_reason "length") ends it
#   "slowly"           slow    — unique rows at 5 tokens/s, ignoring num_predict (the turn limit has to end it)
#   anything else      normal  — a short answer, done_reason "stop"
# It honours options.num_predict (as Ollama does) except in "slow", and logs every request's options and how each
# stream ended (num_predict / natural / client gone / ceiling) to <dir>/streams.jsonl.
# live-28 (A2) — it also stands in for the web-search providers (the app's DEBUG -WebSearchBaseURL points both here):
#   GET /res/v1/web/search, /res/v1/news/search (Brave) and POST /search (Tavily) return 3 synthetic results and log
#   {provider, query} to <dir>/web.jsonl — the switch rows count them (off → none).
# live-29 (B3) — it also logs WHICH endpoint / topic was asked (Brave web|news, Tavily general|news) and serves it back on
#   live-31 (3): GET /chatlog — per chat request, whether the user turn carried the app's results ("Web results the app
#   found today …"), the system prompt the "not from the user" clause, and any social / video host anywhere in it.
#   GET /weblog; a "president" query's results carry Markdown in title and snippet ("#### Tags"), and a "president"
#   question gets a model answer that cites none of them (T's Tavily case: 3 results, "+ web", the training-data line).
# live-32 (2): the invented Lakeview Republic, whose First Minister changed in March 2026 (Mara Quill → Ilsa Vane):
#   GET /w/api.php — a Wikipedia stand-in (search + the article's extract, lead wikitext with the infobox, last edit),
#   logged as provider "wikipedia" with the request's User-Agent; the web results for it are STALE (a Q&A thread, an
#   "as of 2024" page); the model answers from whatever the request carries (Ilsa Vane only if the evidence names her).
#   POST /v1/chat/completions + GET /api/v0/models, /api/v1/models — an LM Studio-style server with a thinking model
#   ("fake/thinker", reasoning off/on): it streams `reasoning_content` first unless the request asks reasoning_effort
#   "none"; /chatlog records the reasoning_effort each request sent.
#   fake_ollama.py <port> <dir> [tokens_per_sec=60]
import json, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT, DIR = int(sys.argv[1]), sys.argv[2]
RATE = float(sys.argv[3]) if len(sys.argv) > 3 else 60.0
MODEL = "qwen3:4b-instruct-2507-q4_K_M"
CEILING_SEC = 900
lock = threading.Lock()
active = {}   # streams still generating: id → {mode, num_predict, tokens, started}
seq = [0]
rewq = []   # live-33 — the app's query rewrites this stub answered
webq = []   # live-29 (B3) — every web request: {provider, endpoint, query}
failed_once = set()   # live-32 (A1) — a "flaky" question fails its first request (HTTP 500), then answers
chatq = []  # live-31 (3) — every chat request: did the user turn carry the app's results, the system prompt the clause, any social host
def log(rec):
    with lock, open(f"{DIR}/streams.jsonl", "a") as f: f.write(json.dumps(rec) + "\n")

def web_results(q):
    ql = q.lower()
    if "presidents" in ql and any(w in ql for w in ("death", "died", "recent")):
        # live-31 (3) — T's shape: a list of people, some of whom died recently. Two social / video hosts lead (the app drops
        # them), then six synthetic encyclopedia results; the first names the most recent death.
        social = [{"title": "VIDEO CLIP presidents (synthetic)", "url": "https://www.youtube.com/watch?v=synthetic",
                   "description": "A clip.", "content": "A clip."},
                  {"title": "SOCIAL POST presidents (synthetic)", "url": "https://www.instagram.com/p/synthetic",
                   "description": "A post.", "content": "A post."}]
        enc = [{"title": f"Presidents and how they died — part {k} (synthetic)", "url": f"https://encyclopedia.gauntlet.example/presidents-{k}",
                "description": "Ezra Pine (synthetic), the most recent president to die, died on 29 December 2024." if k == 1 else f"Synthetic result {k} on the presidents.",
                "content": "Ezra Pine (synthetic), the most recent president to die, died on 29 December 2024." if k == 1 else f"Synthetic result {k} on the presidents."}
               for k in range(1, 7)]
        return social + enc
    if "harbour masters" in ql:   # live-33 — T's TF 202610211551 case: the one result is off-topic (a car-buying page)
        return [{"title": "When Is the Best Time to Buy a New Car? (synthetic)", "url": "https://cars.gauntlet.example/best-time-to-buy",
                 "description": "The best time to buy a new car is at the end of the year, when dealers push to hit their sales targets.",
                 "content": "The best time to buy a new car is at the end of the year, when dealers push to hit their sales targets. October, November and December bring the year-end clearance, and holiday weekends bring discounts on outgoing models."}]
    if "lock keeper" in ql:   # live-33 — on-topic for WebSearchSwitchUI's question (the rerank drops off-topic pages)
        return [{"title": f"Lakeview lock keepers — part {k} (synthetic)", "url": f"https://canals.gauntlet.example/lock-keepers-{k}",
                 "description": f"The Lakeview lock keepers (synthetic): Ada Fenn, keeper since 1998, is living; Tom Reyes, keeper 1960–1990, died in 2019 (part {k}).",
                 "content": f"The Lakeview lock keepers (synthetic): Ada Fenn, keeper since 1998, is living; Tom Reyes, keeper 1960–1990, died in 2019 (part {k})."}
                for k in (1, 2, 3)]
    if "lakeview" in ql or "first minister" in ql: return lakeview_results()   # live-32 (2)
    if "president" in q.lower():   # live-29 (B3) — Markdown in a result, as T's Tavily snippet had
        return [{"title": f"### President of the United States ({k})", "url": f"https://encyclopedia.gauntlet.example/president-{k}",
                 "description": f"#### Tags\nThe sitting president (synthetic result {k}).",
                 "content": f"#### Tags\nThe sitting president (synthetic result {k})."} for k in (1, 2, 3)]
    return [{"title": f"Lakeview Gazette: {q[:40]} ({k})", "url": f"https://news.gauntlet.example/{k}",
             "description": f"Synthetic result {k} about {q[:60]}.", "content": f"Synthetic result {k} about {q[:60]}."}
            for k in (1, 2, 3)]

LAKE_EXTRACT = ("The First Minister of the Lakeview Republic is the head of its government (synthetic). The office was created in 1921. "
                "The incumbent First Minister is Ilsa Vane, who took office on 14 March 2026, succeeding Mara Quill.\n== History ==\n"
                "Mara Quill was First Minister from 2019 until 2026.")
LAKE_WIKITEXT = ("{{Infobox official post\n| post = First Minister\n| incumbent = [[Ilsa Vane]]\n| incumbent_since = {{start date|2026|3|14}}\n}}\n"
                 "The First Minister of the Lakeview Republic heads its government.")
def lakeview_results():
    return [{"title": "Who is the First Minister of Lakeview? - Quora (synthetic)", "url": "https://www.quora.com/lakeview-first-minister",
             "description": "Mara Quill is the First Minister, I think.", "content": "Mara Quill is the First Minister, I think."},
            {"title": "Lakeview cabinet guide (synthetic)", "url": "https://guide.gauntlet.example/lakeview-cabinet",
             "description": "As of 2024, Mara Quill leads the Lakeview cabinet as First Minister.",
             "content": "As of 2024, Mara Quill leads the Lakeview cabinet as First Minister."},
            {"title": "Lakeview Republic profile (synthetic)", "url": "https://atlas.gauntlet.example/lakeview",
             "description": "The Lakeview Republic is a parliamentary republic on the northern lakes.",
             "content": "The Lakeview Republic is a parliamentary republic on the northern lakes."}]
def lakeview_answer(allc):
    if "ilsa vane" in allc:
        return ["The", " current", " First", " Minister", " of", " the", " Lakeview", " Republic", " is", " Ilsa", " Vane", ",",
                " in", " office", " since", " 14", " March", " 2026", " [1]", "."]
    return ["The", " First", " Minister", " of", " the", " Lakeview", " Republic", " is", " Mara", " Quill", "."]

def tokens(mode):
    if mode == "deaths":   # live-31 (3) — an answer from the results, citing [1]
        yield from ["According", " to", " the", " results", ",", " Ezra", " Pine", " was", " the", " most", " recent", " to", " die",
                    ",", " on", " 29", " December", " 2024", " [1]", "."]
        return
    if mode == "president":   # live-29 (B3) — an answer that cites none of the results
        yield from ["The", " sitting", " president", " is", " named", " in", " the", " results", "."]
        return
    if mode.startswith("long"):   # live-29 (C1) — a realistic multi-paragraph answer, ending with the turn's marker
        k = mode[4:] or "?"
        paras = [f"The harbour log for week {k} records two high waters a day at the north wall.",
                 f"In week {k} the spring tide arrived mid-week and the neap came at the end.",
                 f"The harbour master noted {k} moorings changing hands and a new buoy at the bar.",
                 f"Rain kept the fishing fleet in on day {k} of the month, and the crane was serviced.",
                 f"By the weekend of week {k} the ferry was back on its timetable."]   # distinct lines: the loop guard stays quiet
        body = ("## What the log says\n\n" + " ".join(paras[:3]) + "\n\n- The dredger worked four mornings.\n- The ferry ran late twice.\n"
                "- The slipway closed for crane servicing.\n\n" + " ".join(paras[3:]) + "\n\nEnd of answer " + k + ".")
        for w in body.split(" "):
            yield w + " "
        return
    if mode == "normal":
        yield from ["A", " tide", " pool", " is", " a", " rocky", " hollow", " the", " sea", " refills", " twice", " a", " day", "."]
        return
    yield from ["As", " of", " my", " training", " data", ",", " here", " is", " the", " table", ":\n\n"]
    yield from ["| # | Name | Years | Living? |\n", "|---|------|-------|---------|\n"]
    k = 0
    while True:
        k += 1
        if mode == "loop" and k > 15:
            row = ["| 23 |", " Mayor", " Pim", " 23 |", " 1881", "–1885", " |", " No", " |\n"]
        else:
            row = [f"| {k} |", " Keeper", f" {k}", " |", f" {1700 + k}", f"–{1760 + k}", " |", " No", " |\n"]
        yield from row

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send_json(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_web(self, provider, q, endpoint=""):
        rec = {"provider": provider, "endpoint": endpoint, "query": q, "at": time.strftime("%H:%M:%S")}
        with lock:
            webq.append(rec)
            with open(f"{DIR}/web.jsonl", "a") as f: f.write(json.dumps(rec) + "\n")
    def do_GET(self):
        if self.path.startswith("/res/v1/"):   # Brave web / news
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query).get("q", [""])[0]
            self.log_web("brave", q, "news" if "/news/" in self.path else "web")
            r = web_results(q)
            self.send_json({"web": {"results": r}} if "/web/" in self.path else {"results": r}); return
        model = {"name": MODEL, "model": MODEL, "digest": "fake", "size": 1, "size_vram": 1, "context_length": 20480,
                 "expires_at": "2319-01-01T00:00:00Z", "details": {"family": "qwen3", "parameter_size": "4.0B"}}
        if self.path.startswith("/w/api.php"):   # live-32 (2) — Wikipedia
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            ua = self.headers.get("User-Agent", "")
            if qs.get("generator", [""])[0] == "search":   # live-33 — one request: the top articles' leads
                s = qs.get("gsrsearch", [""])[0].lower()
                self.log_web("wikipedia", s, "generator|" + ua)
                pages = [{"title": "Lakeview (disambiguation)", "index": 1, "extract": "Lakeview may refer to:", "pageprops": {"disambiguation": ""}},
                         {"title": "First Minister of the Lakeview Republic", "index": 2, "extract": LAKE_EXTRACT.split("\n==")[0],
                          "revisions": [{"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 2 * 86400)),
                                         "slots": {"main": {"content": LAKE_WIKITEXT}}}]}] if ("lakeview" in s or "first minister" in s) and "harbour" not in s else []
                self.send_json({"query": {"pages": pages}} if pages else {"batchcomplete": True}); return
            if qs.get("list", [""])[0] == "search":
                s = qs.get("srsearch", [""])[0]
                self.log_web("wikipedia", s, "search|" + ua)
                hits = [{"title": "Lakeview (disambiguation)"}, {"title": "First Minister of the Lakeview Republic"}] if ("lakeview" in s or "first minister" in s) else []
                self.send_json({"query": {"search": hits}}); return
            t = qs.get("titles", [""])[0]
            self.log_web("wikipedia", t, "page|" + ua)
            self.send_json({"query": {"pages": [{"title": t, "extract": LAKE_EXTRACT,
                "revisions": [{"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 2 * 86400)),
                               "slots": {"main": {"content": LAKE_WIKITEXT}}}]}]}}); return
        if self.path.startswith("/api/v0/models"):   # live-32 (2) — LM Studio
            self.send_json({"data": [{"id": "fake/thinker"}]}); return
        if self.path.startswith("/api/v1/models"):
            self.send_json({"models": [{"key": "fake/thinker", "capabilities": {"reasoning": {"allowed_options": ["off", "on"], "default": "on"}}}]}); return
        if self.path.startswith("/rewritelog"):
            with lock: self.send_json(list(rewq)); return
        if self.path.startswith("/weblog"):
            with lock: self.send_json(list(webq)); return
        if self.path.startswith("/chatlog"):
            with lock: self.send_json(list(chatq)); return
        if self.path.startswith("/status"):   # what is still generating right now (the Mac's view)
            now = time.time()
            with lock: self.send_json([{**v, "ageSec": round(now - v["started"], 1)} for v in active.values()]); return
        if self.path.startswith("/api/version"): self.send_json({"version": "0.13.2"})
        elif self.path.startswith("/api/tags"): self.send_json({"models": [model]})
        elif self.path.startswith("/api/ps"): self.send_json({"models": [model]})
        else: self.send_json({})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path.startswith("/search"):   # Tavily
            self.log_web("tavily", body.get("query", ""), body.get("topic", ""))
            self.send_json({"results": web_results(body.get("query", ""))}); return
        if self.path.startswith("/v1/chat/completions"):   # live-32 (2) — LM Studio, a thinking model
            msgs = body.get("messages", [])
            rw = rewrite_reply(msgs)
            if rw is not None and not body.get("stream"):
                with lock: rewq.append({"query": rw, "at": time.strftime("%H:%M:%S")})
                self.send_json({"choices": [{"index": 0, "message": {"role": "assistant", "content": rw}}]}); return
            allc = " ".join(str(m.get("content", "")) for m in msgs).lower()
            q = next((str(m.get("content", "")) for m in reversed(msgs) if m.get("role") == "user"), "").lower()
            effort = body.get("reasoning_effort")
            with lock: chatq.append({"route": "server", "user_head": q[:140], "reasoning_effort": effort, "app_results": q.startswith("web results the app found today"),
                                     "computed_fact": "computed fact" in allc, "wikipedia": "wikipedia:" in allc, "at": time.strftime("%H:%M:%S")})
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            def sse(delta):
                b = ("data: " + json.dumps({"choices": [{"index": 0, "delta": delta}]}) + "\n\n").encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(b), b)); self.wfile.flush()
            try:
                if effort != "none":
                    for w in ["Thinking", " Process", ":", " 1.", " Analyze", " the", " request", "."]: sse({"reasoning_content": w}); time.sleep(0.05)
                toks = lakeview_answer(allc) if ("lakeview" in q or "first minister" in q) else ["A", " tide", " pool", "."]
                for w in toks: sse({"content": w}); time.sleep(1.0 / RATE)
                b = b"data: [DONE]\n\n"; self.wfile.write(b"%x\r\n%s\r\n" % (len(b), b)); self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if not self.path.startswith("/api/chat"):
            self.send_json({"done": True, "model": MODEL}); return
        q = next((m.get("content", "") for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "").lower()
        rw = rewrite_reply(body.get("messages", []))
        if rw is not None:
            with lock: rewq.append({"query": rw, "at": time.strftime("%H:%M:%S")})
            self.send_json({"model": MODEL, "message": {"role": "assistant", "content": rw}, "done": True}) if not body.get("stream", True) else None
            if body.get("stream", True):
                self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
                for obj in ({"model": MODEL, "message": {"role": "assistant", "content": rw}, "done": False},
                            {"model": MODEL, "message": {"role": "assistant", "content": ""}, "done": True, "done_reason": "stop"}):
                    b = (json.dumps(obj) + "\n").encode(); self.wfile.write(b"%x\r\n%s\r\n" % (len(b), b))
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            return
        if "flaky" in q:   # live-32 (A1)
            with lock:
                first = q not in failed_once; failed_once.add(q)
                chatq.append({"user_head": q[:140], "flaky": True, "failed": first, "at": time.strftime("%H:%M:%S")})
            if first:
                b = b'{"error":"synthetic failure"}'; self.send_response(500); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        import re as _re
        lm = _re.search(r"harbour log turn (\d+)", q)
        msgs = body.get("messages", [])
        allc = " ".join(str(m.get("content", "")) for m in msgs).lower()
        sysc = next((str(m.get("content", "")) for m in msgs if m.get("role") == "system"), "")
        with lock: chatq.append({"user_head": q[:140], "app_results": q.startswith("web results the app found today"),
                                 "clause": "not from the user" in sysc, "social": "youtube.com" in allc or "instagram.com" in allc,
                                 "tool_messages": sum(1 for m in msgs if m.get("role") == "tool"), "at": time.strftime("%H:%M:%S"),
                                 "computed_fact": "computed fact" in allc, "wikipedia": "wikipedia:" in allc})
        deaths = ("cause" in q and "death" in q) or "most recent to go" in q
        lake = "lakeview" in q or "first minister" in q   # live-32 (2)
        mode = "lakeview" if lake else ("long" + lm.group(1)) if lm else "president" if "current president" in q else "deaths" if deaths else "loop" if "presidents" in q else "unique" if "every lighthouse" in q else "slow" if "slowly" in q else "normal"
        opts = body.get("options") or {}
        limit = opts.get("num_predict") if mode != "slow" else None
        rate = 5.0 if mode == "slow" else RATE
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        def chunk(obj):
            b = (json.dumps(obj) + "\n").encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(b), b)); self.wfile.flush()
        t0, count, ended = time.time(), 0, "natural"
        with lock: seq[0] += 1; sid = seq[0]; active[sid] = {"mode": mode, "num_predict": opts.get("num_predict"), "tokens": 0, "started": t0}
        try:
            for tok in (lakeview_answer(allc) if mode == "lakeview" else tokens(mode)):
                if limit is not None and count >= limit: ended = "num_predict"; break
                if time.time() - t0 > CEILING_SEC: ended = "ceiling"; break
                chunk({"model": MODEL, "message": {"role": "assistant", "content": tok}, "done": False})
                count += 1
                with lock: active[sid]["tokens"] = count
                time.sleep(1.0 / rate)
            chunk({"model": MODEL, "message": {"role": "assistant", "content": ""}, "done": True,
                   "done_reason": "length" if ended == "num_predict" else "stop", "eval_count": count,
                   "prompt_eval_count": 50})
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            ended = "client gone"
        with lock: active.pop(sid, None)
        log({"mode": mode, "num_predict": opts.get("num_predict"), "num_ctx": opts.get("num_ctx"), "tokens": count,
             "sec": round(time.time() - t0, 1), "ended": ended, "at": time.strftime("%H:%M:%S")})

def rewrite_reply(msgs):
    """live-33 — the app's query rewrite ("You write web search queries…"): the latest question as a short query."""
    sysc = next((str(m.get("content", "")) for m in msgs if m.get("role") == "system"), "")
    if not sysc.startswith("You write web search queries"): return None
    u = next((str(m.get("content", "")) for m in reversed(msgs) if m.get("role") == "user"), "")
    import re as _re
    m = _re.search(r"Latest question: (.*?)\n", u + "\n")
    latest = (m.group(1) if m else u).lower()
    if "harbour masters" in latest: return "Lakeview harbour masters list"
    if "lakeview" in u.lower() or "first minister" in latest: return "Lakeview Republic First Minister"
    prior = _re.findall(r"^Question: (.*)$", u, _re.M)   # a follow-up: the earlier question's topic carries, as a real rewrite's does
    clean = lambda t: _re.sub(r"[^a-z0-9 ]", "", t.lower()).strip()
    return ((clean(prior[0]) + " " if prior else "") + clean(latest))[:120] or "tide pools"

ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
