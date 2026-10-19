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
#   GET /weblog; a "president" query's results carry Markdown in title and snippet ("#### Tags"), and a "president"
#   question gets a model answer that cites none of them (T's Tavily case: 3 results, "+ web", the training-data line).
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
webq = []   # live-29 (B3) — every web request: {provider, endpoint, query}
def log(rec):
    with lock, open(f"{DIR}/streams.jsonl", "a") as f: f.write(json.dumps(rec) + "\n")

def web_results(q):
    if "president" in q.lower():   # live-29 (B3) — Markdown in a result, as T's Tavily snippet had
        return [{"title": f"### President of the United States ({k})", "url": f"https://encyclopedia.gauntlet.example/president-{k}",
                 "description": f"#### Tags\nThe sitting president (synthetic result {k}).",
                 "content": f"#### Tags\nThe sitting president (synthetic result {k})."} for k in (1, 2, 3)]
    return [{"title": f"Lakeview Gazette: {q[:40]} ({k})", "url": f"https://news.gauntlet.example/{k}",
             "description": f"Synthetic result {k} about {q[:60]}.", "content": f"Synthetic result {k} about {q[:60]}."}
            for k in (1, 2, 3)]

def tokens(mode):
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
        if self.path.startswith("/weblog"):
            with lock: self.send_json(list(webq)); return
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
        if not self.path.startswith("/api/chat"):
            self.send_json({"done": True, "model": MODEL}); return
        q = next((m.get("content", "") for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "").lower()
        import re as _re
        lm = _re.search(r"harbour log turn (\d+)", q)
        mode = ("long" + lm.group(1)) if lm else "president" if "current president" in q else "loop" if "presidents" in q else "unique" if "every lighthouse" in q else "slow" if "slowly" in q else "normal"
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
            for tok in tokens(mode):
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

ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
