#!/usr/bin/env python3
# live-18 (0a) — a fake "AirPad Host + Ollama" pair for test_restore.sh, on scratch ports only. It reproduces the
# behaviour the restore depends on, nothing more:
#   ollama <port> <dir>               /api/version · /api/ps · /api/tags · /api/generate (load with keep_alive + num_ctx)
#                                     + (1.1-D) /api/show · /api/pull · /api/chat · /v1/models · /v1/chat/completions
#   lmstudio <port> <dir>             (1.1-D) an LM Studio 0.4 fake: /api/v1/models (+ load/unload/download/status),
#                                     /v1/models, /v1/chat/completions; FAKE_LMS_TOKEN → bearer required
#   host <port> <ollama-port> <dir>   on start: if an Ollama already answers on <ollama-port> it ATTACHES (does not
#                                     spawn — the real Host's "[ollama] already serving … attaching"); otherwise it
#                                     spawns its own fake Ollama, and kills it when it quits (as the real Host does).
#                                     /health · /v1/models/load (always-on: keep_alive -1, num_ctx 20480, marks held
#                                     in <dir>/residency.json) · /v1/models/eject.
#                                     FAKE_HOST_NO_SPAWN=1 → never spawns (an Ollama that can't start).
#   ctl running|open|quit <dir> <host-port> <ollama-port>
#                                     the Host-control commands the restore runs: `open` is a no-op when the Host is
#                                     already running (as `open -a` is); `quit` stops it (and the Ollama it spawned).
# State lives in <dir>/ps.json (what the "Ollama" has resident), so a restarted Ollama starts empty, as a real one does.
import json, os, signal, subprocess, sys, threading, time, urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def answers(port):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/api/version", timeout=1).read(); return True
    except Exception:
        return False

def serve(port, handler):
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()

class Base(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

def run_ollama(port, d):
    # 1.1-D — also the app's custom-server fake: /api/show · /api/pull (streamed progress; a "30b" pull is refused for
    # disk, verbatim) · /api/chat (native, NDJSON) · /v1/models · /v1/chat/completions · /_fake/stats. Both chat paths
    # follow Ollama's reload rule: a request whose window differs from the loaded one reloads the model (counted).
    # The /v1 path can't carry num_ctx, so it runs at FAKE_OLLAMA_DEFAULT_CTX (4096) — the hypothesis the real-server
    # check confirms or corrects.
    ps = os.path.join(d, "ps.json")
    tags = os.path.join(d, "tags.json")
    def reset():
        json.dump({"models": []}, open(ps, "w"))   # a fresh Ollama has nothing resident
        json.dump({"models": [{"name": n, "model": n, "digest": "fake-" + n, "size": sz} for n, sz in
                              (("qwen3:8b-q4_K_M", 5225388164), ("llama3.2:latest", 2019393189))]}, open(tags, "w"))
    reset()
    stats = {"reloads": 0, "last_chat_path": None, "last_num_ctx": None, "last_keep_alive": None, "last_roles": None}
    default_ctx = int(os.environ.get("FAKE_OLLAMA_DEFAULT_CTX", "4096"))
    def expiry(ka):
        if ka in (-1, "-1"): return "2319-01-01T00:00:00Z"
        secs = int(ka) if isinstance(ka, int) else int(str(ka).rstrip("s")) if str(ka).endswith("s") else int(str(ka).rstrip("m")) * 60
        return (datetime.now(timezone.utc) + timedelta(seconds=secs)).isoformat()
    def serve_model(name, ctx, ka):
        """What Ollama does on any request naming a model: load it (reload if the window differs)."""
        state = json.load(open(ps)); cur = [m for m in state["models"] if m["name"] == name]
        if cur and cur[0]["context_length"] != ctx: stats["reloads"] += 1
        state["models"] = [m for m in state["models"] if m["name"] != name]
        if ka not in (0, "0"):
            state["models"].append({"name": name, "model": name, "context_length": ctx, "expires_at": expiry(ka)})
        json.dump(state, open(ps, "w"))
    class H(Base):
        def stream_lines(self, lines, ctype="application/x-ndjson", delay=0.02):
            self.send_response(200); self.send_header("Content-Type", ctype); self.end_headers()
            for l in lines:
                self.wfile.write(l.encode()); self.wfile.flush(); time.sleep(delay)
        def do_GET(self):
            if self.path == "/api/version": return self.send(200, {"version": os.environ.get("FAKE_OLLAMA_VERSION", "fake")})
            if self.path == "/api/ps": return self.send(200, json.load(open(ps)))
            if self.path == "/api/tags": return self.send(200, json.load(open(tags)))
            if self.path == "/v1/models":
                return self.send(200, {"object": "list", "data": [{"id": m["name"], "object": "model"} for m in json.load(open(tags))["models"]]})
            if self.path == "/_fake/stats": return self.send(200, stats)
            self.send(404, {})
        def do_POST(self):
            b = self.body()
            if self.path == "/_fake/reset": reset(); return self.send(200, {"reset": True})   # UI tests: a fresh server
            if self.path == "/api/show":
                n = b.get("model", "")
                caps = ["completion", "tools"] + (["thinking"] if n.startswith("qwen3:8b") else [])
                return self.send(200, {"capabilities": caps, "model_info": {"general.architecture": "qwen3", "qwen3.context_length": 40960}})
            if self.path == "/api/pull":
                n = b.get("model", "")
                if "30b" in n:
                    return self.stream_lines([json.dumps({"status": "pulling manifest"}) + "\n",
                                              json.dumps({"error": "not enough disk space to pull this model (fake)"}) + "\n"])
                lines = [json.dumps({"status": "pulling manifest"}) + "\n"]
                for done in (0, 300, 600, 900):
                    lines.append(json.dumps({"status": "pulling a1", "digest": "sha256:a1", "total": 900, "completed": done}) + "\n")
                lines.append(json.dumps({"status": "pulling b2", "digest": "sha256:b2", "total": 100, "completed": 100}) + "\n")
                lines += [json.dumps({"status": "verifying sha256 digest"}) + "\n", json.dumps({"status": "success"}) + "\n"]
                t = json.load(open(tags))
                if not any(m["name"] == n for m in t["models"]):
                    t["models"].append({"name": n, "model": n, "digest": "fake-" + n, "size": 2497293803}); json.dump(t, open(tags, "w"))
                return self.stream_lines(lines, delay=0.15)
            if self.path in ("/api/chat", "/v1/chat/completions"):
                name = b["model"]; native = self.path == "/api/chat"
                ctx = (b.get("options") or {}).get("num_ctx", default_ctx) if native else default_ctx
                stats.update(last_chat_path=self.path, last_num_ctx=ctx,
                             last_keep_alive=str(b["keep_alive"]) if "keep_alive" in b else "none",
                             last_roles=[m.get("role") for m in b.get("messages", [])], last_think=b.get("think", "none"))
                serve_model(name, ctx, b.get("keep_alive", "5m"))
                words = ["This ", "is ", "a ", "fake ", "answer."]
                if native and not b.get("stream", True):
                    return self.send(200, {"model": name, "message": {"role": "assistant", "content": "".join(words)}, "done": True})
                if native:
                    return self.stream_lines([json.dumps({"model": name, "message": {"role": "assistant", "content": w}, "done": False}) + "\n" for w in words]
                                             + [json.dumps({"model": name, "message": {"role": "assistant", "content": ""}, "done": True, "done_reason": "stop"}) + "\n"])
                return self.stream_lines(["data: " + json.dumps({"choices": [{"index": 0, "delta": {"content": w}}]}) + "\n\n" for w in words]
                                         + ["data: [DONE]\n\n"], ctype="text/event-stream")
            if self.path != "/api/generate": return self.send(404, {})
            name = b["model"]; ka = b.get("keep_alive", "15m")
            ctx = (b.get("options") or {}).get("num_ctx", 4096)
            stats["last_generate"] = {"model": name, "keep_alive": str(b["keep_alive"]) if "keep_alive" in b else "none", "num_ctx": ctx}
            state = json.load(open(ps)); state["models"] = [m for m in state["models"] if m["name"] != name]
            if ka not in (0, "0"):
                state["models"].append({"name": name, "model": name, "context_length": ctx, "expires_at": expiry(ka)})
            json.dump(state, open(ps, "w")); self.send(200, {"done": True})
    serve(port, H)

def run_lmstudio(port, d):
    # 1.1-D — an LM Studio 0.4 fake (the documented /api/v1 shapes). FAKE_LMS_TOKEN set → every request needs that bearer.
    token = os.environ.get("FAKE_LMS_TOKEN")
    models = [{"type": "llm", "key": "qwen/qwen3-8b", "display_name": "Qwen3 8B", "size_bytes": 5030000000,
               "loaded_instances": [], "max_context_length": 40960, "format": "gguf",
               "capabilities": {"vision": False, "trained_for_tool_use": True, "reasoning": {"allowed_options": ["off", "on"], "default": "on"}}},
              {"type": "embedding", "key": "text-embedding-nomic-embed-text-v1.5", "size_bytes": 84106624, "loaded_instances": []}]
    jobs = {}
    stats = {"reloads": 0, "last_load_context": None, "last_chat_model": None, "last_unload": None}
    def find(k): return next((m for m in models if m["key"] == k), None)
    def load(k, ctx):
        m = find(k); m["loaded_instances"] = [{"id": k, "config": {"context_length": ctx, "eval_batch_size": 512}}]
    class H(Base):
        def authed(self):
            if not token or self.path == "/_fake/stats": return True
            if self.headers.get("Authorization") == "Bearer " + token: return True
            self.send(401, {"error": {"message": "Invalid or missing API token", "type": "invalid_request_error"}}); return False
        def do_GET(self):
            if not self.authed(): return
            if self.path == "/api/v1/models": return self.send(200, {"models": models})
            if self.path == "/v1/models":
                return self.send(200, {"object": "list", "data": [{"id": m["key"], "object": "model"} for m in models]})
            if self.path.startswith("/api/v1/models/download/status/"):
                j = jobs.get(self.path.rsplit("/", 1)[1])
                if not j: return self.send(404, {"error": {"message": "No such job"}})
                j["polls"] += 1; total = 2497280000
                if j["polls"] >= 3:
                    # Real LM Studio lists the model a moment AFTER the job reads "completed" (seen on T's server, 1.1-D).
                    if not j.get("listing"):
                        j["listing"] = True
                        threading.Timer(2.5, lambda: find(j["model"]) or models.append(
                            {"type": "llm", "key": j["model"], "size_bytes": total, "loaded_instances": [], "max_context_length": 262144,
                             "capabilities": {"vision": False, "trained_for_tool_use": True}})).start()
                    return self.send(200, {"job_id": j["id"], "status": "completed", "total_size_bytes": total, "downloaded_bytes": total})
                return self.send(200, {"job_id": j["id"], "status": "downloading", "total_size_bytes": total,
                                       "downloaded_bytes": total * j["polls"] // 3})
            if self.path == "/_fake/stats": return self.send(200, stats)
            self.send(404, {"error": f"Unexpected endpoint or method. (GET {self.path})"})
        def do_POST(self):
            if not self.authed(): return
            b = self.body()
            if self.path == "/api/v1/models/load":
                if not find(b["model"]): return self.send(404, {"error": {"message": f"Model {b['model']} not found"}})
                ctx = b.get("context_length", 4096); stats["last_load_context"] = ctx; load(b["model"], ctx)
                return self.send(200, {"type": "llm", "instance_id": b["model"], "load_time_seconds": 0.4, "status": "loaded"})
            if self.path == "/api/v1/models/unload":
                for m in models: m["loaded_instances"] = [i for i in m["loaded_instances"] if i["id"] != b["instance_id"]]
                stats["last_unload"] = b["instance_id"]; return self.send(200, {"instance_id": b["instance_id"]})
            if self.path == "/api/v1/models/download":
                if find(b["model"]): return self.send(200, {"status": "already_downloaded"})
                jid = "job_%04d" % len(jobs); jobs[jid] = {"id": jid, "model": b["model"], "polls": 0}
                return self.send(200, {"job_id": jid, "status": "downloading", "total_size_bytes": 2497280000})
            if self.path == "/v1/chat/completions":
                m = next((x for x in models if any(i["id"] == b["model"] for i in x["loaded_instances"]) or x["key"] == b["model"]), None)
                if not m: return self.send(404, {"error": {"message": f"Model {b['model']} not found"}})
                if not m["loaded_instances"]: stats["reloads"] += 1; load(m["key"], 4096)   # JIT load at the default
                stats["last_chat_model"] = b["model"]
                self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
                for w in ["This ", "is ", "a ", "fake ", "answer."]:
                    self.wfile.write(("data: " + json.dumps({"choices": [{"index": 0, "delta": {"content": w}}]}) + "\n\n").encode()); self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n"); return
            self.send(404, {"error": f"Unexpected endpoint or method. (POST {self.path})"})
    serve(port, H)

def run_host(port, oport, d):
    child = None
    if answers(oport):
        print(f"[ollama] already serving on 127.0.0.1:{oport} — attaching (not spawning)", flush=True)
    elif os.environ.get("FAKE_HOST_NO_SPAWN") != "1":
        child = subprocess.Popen([sys.executable, __file__, "ollama", str(oport), d])
        print(f"[ollama] spawned pid={child.pid}", flush=True)
    def bye(*_):
        if child: child.terminate()
        sys.exit(0)
    signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGINT, bye)
    res = os.path.join(d, "residency.json")
    if not os.path.exists(res): json.dump({"mode": "always-on", "held": []}, open(res, "w"))
    def ollama(path, body):
        req = urllib.request.Request(f"http://127.0.0.1:{oport}{path}", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    class H(Base):
        def do_GET(self):
            if self.path == "/health": return self.send(200, {"ok": True, "hostPublicKey": "fake"})
            self.send(404, {})
        def do_POST(self):
            if self.headers.get("Authorization") != "Bearer fake-token": return self.send(401, {})
            b = self.body(); name = b.get("catalogId") or b.get("model")
            try:
                if self.path == "/v1/models/load":
                    ollama("/api/generate", {"model": name, "keep_alive": -1, "options": {"num_ctx": 20480}})
                    r = json.load(open(res)); r["held"] = sorted(set(r["held"]) | {name}); json.dump(r, open(res, "w"))
                    return self.send(200, {"result": "loaded", "tag": name})
                if self.path == "/v1/models/eject":
                    ollama("/api/generate", {"model": name, "keep_alive": 0})
                    r = json.load(open(res)); r["held"] = [h for h in r["held"] if h != name]; json.dump(r, open(res, "w"))
                    return self.send(200, {"result": "ejected"})
            except Exception:
                return self.send(502, {"error": {"code": "upstream_error", "message": "load failed"}})
            self.send(404, {})
    serve(port, H)

def ctl(cmd, d, hport, oport):
    pidf = os.path.join(d, "host.pid")
    def alive():
        try: os.kill(int(open(pidf).read()), 0); return True
        except Exception: return False
    if cmd == "running": sys.exit(0 if alive() else 1)
    if cmd == "open":
        if alive(): return
        p = subprocess.Popen([sys.executable, __file__, "host", hport, oport, d],
                             stdout=open(os.path.join(d, "host.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
        open(pidf, "w").write(str(p.pid))
    if cmd == "quit" and alive():
        pid = int(open(pidf).read()); os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            try: os.kill(pid, 0); time.sleep(0.1)
            except Exception: break

if __name__ == "__main__":
    kind = sys.argv[1]
    if kind == "ctl": ctl(*sys.argv[2:6])
    if kind == "ollama": run_ollama(int(sys.argv[2]), sys.argv[3])
    elif kind == "lmstudio": run_lmstudio(int(sys.argv[2]), sys.argv[3])
    elif kind == "host": run_host(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
