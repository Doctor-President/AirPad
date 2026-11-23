"""Sweep 2b · 3.2 — the keyword-relevance spike: shared pieces (paths, guards, tokenizers, library loading).

Design: Ops design-refs/sweep-2b/relevance-spike-design.md. Python 3.14, numpy only here.

Privacy: a library loaded with private=True (T's fixture) is held in memory only. Nothing in this folder writes its
text, titles or questions anywhere; `say()` refuses to print a string marked private. Reports carry IDs and numbers.
"""
from __future__ import annotations

import json
import math
import os
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
OUT = Path(os.environ.get("RELEVANCE_OUT", REPO / "build" / "sweep2b" / "relevance"))
BENCHMARK = HERE.parent / "benchmark"
SAMPLE_NODES = REPO / "AirPad" / "Resources" / "SampleLibrary" / "nodes"
FIXTURE_DEFAULT = Path.home() / "Developer" / "fixtures" / "tom-corpus-2026-09-21"

# Never T's Ollama (11434) or LM Studio (1234). Nothing here talks to a server; the guard makes sure no argument or
# environment value points at one either (the reranker runs in-process with MLX).
FORBIDDEN_PORT = re.compile(r"(?::|port[= ]?)(11434|1234)(?!\d)", re.I)


def refuse_forbidden_ports(argv=None, env=None):
    argv = sys.argv if argv is None else argv
    env = os.environ if env is None else env
    for v in list(argv) + [f"{k}={v}" for k, v in env.items()]:
        if FORBIDDEN_PORT.search(str(v)):
            sys.exit(f"refusing: {str(v).split('=')[0]} names port 11434 or 1234 (T's servers)")


class Private(str):
    """A string from T's fixture. Never printed or written; `say` and `dump_json` refuse it."""


def say(*parts):
    for p in parts:
        if isinstance(p, Private):
            raise RuntimeError("refusing to print fixture text")
    print(*parts, flush=True)


def dump_json(obj, path):
    def check(o):
        if isinstance(o, Private):
            raise RuntimeError(f"refusing to write fixture text to {path}")
        if isinstance(o, dict):
            for k, v in o.items():
                check(k), check(v)
        elif isinstance(o, (list, tuple)):
            for v in o:
                check(v)
    check(obj)
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)


# ---------------------------------------------------------------------------------------------------------------
# Tokenizer A: a port of the app's `LibrarianState.contentTokens` (lowercase, split on non letter/number, >= 3
# characters, its stop list, its plural stem), returning counts instead of a set.
A_STOP = {
    "the", "and", "for", "with", "about", "what", "whats", "tell", "does", "did",
    "entry", "note", "notes", "document", "documents", "article", "articles", "page", "pages",
    "this", "that", "these", "those", "your", "you", "reveal", "reveals", "say", "says",
    "have", "has", "are", "was", "were", "can", "how", "why", "who", "when", "where", "which",
    "from", "into", "get", "got", "any", "all", "some", "more", "call", "called", "named",
    "titled", "show", "give", "find", "want", "would", "could", "should", "please", "thing"}

# `LibrarianState.commonTitleWords` (title matching: these can't be the two shared words that name an entry).
COMMON_TITLE_WORDS = {
    "keep", "kept", "coming", "come", "came", "back", "going", "goe", "way", "time", "still", "again", "first", "last",
    "new", "old", "good", "bad", "little", "long", "big", "small", "make", "made", "take", "took", "thing", "lot", "really",
    "just", "like", "one", "two", "day", "year", "week", "today", "now", "then", "never", "always", "ever", "around", "out",
    "off", "over", "after", "before", "about", "think", "thought", "know", "knew", "want", "need", "feel", "felt", "look",
    "looking", "see", "saw", "write", "wrote", "written", "said", "tell", "told", "use", "used", "work", "worked", "start",
    "started", "stop", "end", "ended", "try", "tried", "put", "set", "get", "getting", "doing", "done", "being", "having",
    "why", "not", "but", "own", "mine", "more", "most", "less", "much", "many", "very", "too", "also", "only"}

_SPLIT = re.compile(r"[^\w]|_", re.UNICODE)


def _words(s):
    return [w for w in _SPLIT.split(s.lower()) if w]


def stem_a(w):
    if len(w) > 4 and w.endswith("ies"):
        return w[:-3] + "y"
    if len(w) > 3 and w.endswith("s") and not w.endswith("ss"):
        return w[:-1]
    return w


def tokens_a(s):
    return [stem_a(w) for w in _words(s) if len(w) >= 3 and w not in A_STOP]


# Tokenizer B: accents folded, the Snowball (Porter2) English stem, a standard stop list (NLTK's English list, 179
# words), 2-character tokens kept only when they hold a digit.
B_STOP = set("""i me my myself we our ours ourselves you you're you've you'll you'd your yours yourself yourselves he
him his himself she she's her hers herself it it's its itself they them their theirs themselves what which who whom
this that that'll these those am is are was were be been being have has had having do does did doing a an the and but
if or because as until while of at by for with about against between into through during before after above below to
from up down in out on off over under again further then once here there when where why how all any both each few more
most other some such no nor not only own same so than too very s t can will just don don't should should've now d ll m
o re ve y ain aren aren't couldn couldn't didn didn't doesn doesn't hadn hadn't hasn hasn't haven haven't isn isn't ma
mightn mightn't mustn mustn't needn needn't shan shan't shouldn shouldn't wasn wasn't weren weren't won won't wouldn
wouldn't""".split())


def fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


def tokens_b(s):
    out = []
    for w in _words(fold(s.replace("’", "'"))):
        if w in B_STOP:
            continue
        if len(w) >= 3 or (len(w) == 2 and any(c.isdigit() for c in w)):
            out.append(porter2(w))
    return out


TOKENIZERS = {"A": tokens_a, "B": tokens_b}


# ---------------------------------------------------------------------------------------------------------------
# Porter2 (the Snowball English stemmer), written out here because the spike may use numpy + mlx-lm only.
_V = set("aeiouy")
_DOUBLES = ("bb", "dd", "ff", "gg", "mm", "nn", "pp", "rr", "tt")
_LI = set("cdeghkmnrt")
_EXC1 = {"skis": "ski", "skies": "sky", "dying": "die", "lying": "lie", "tying": "tie", "idly": "idl", "gently": "gentl",
         "ugly": "ugli", "early": "earli", "only": "onli", "singly": "singl", "sky": "sky", "news": "news", "howe": "howe",
         "atlas": "atlas", "cosmos": "cosmos", "bias": "bias", "andes": "andes"}
_EXC2 = {"inning", "outing", "canning", "herring", "earring", "proceed", "exceed", "succeed"}


def _is_v(c):
    return c in _V


def _regions(w):
    def after(start):
        for i in range(start + 1, len(w)):
            if not _is_v(w[i]) and _is_v(w[i - 1]):
                return i + 1
        return len(w)
    r1 = None
    for p in ("gener", "commun", "arsen"):
        if w.startswith(p):
            r1 = len(p)
    if r1 is None:
        r1 = after(0) if len(w) > 1 else len(w)
        # `after` looks for vowel then non-vowel starting from index 1
    r2 = len(w)
    for i in range(r1 + 1, len(w)):
        if not _is_v(w[i]) and _is_v(w[i - 1]):
            r2 = i + 1
            break
    return r1, r2


def _short_syllable_at_end(w):
    if len(w) == 2:
        return _is_v(w[0]) and not _is_v(w[1])
    if len(w) >= 3:
        return (not _is_v(w[-3]) and _is_v(w[-2]) and not _is_v(w[-1]) and w[-1] not in "wxY")
    return False


def porter2(word):
    w = word.lower()
    if len(w) <= 2:
        return w
    if w in _EXC1:
        return _EXC1[w]
    if w.startswith("'"):
        w = w[1:]
    if w.startswith("y"):
        w = "Y" + w[1:]
    w = "".join("Y" if (c == "y" and i > 0 and _is_v(w[i - 1])) else c for i, c in enumerate(w))
    r1, r2 = _regions(w)
    # Step 0
    for s in ("'s'", "'s", "'"):
        if w.endswith(s):
            w = w[: -len(s)]
            break
    # Step 1a
    if w.endswith("sses"):
        w = w[:-2]
    elif w.endswith("ied") or w.endswith("ies"):
        w = w[:-2] if len(w) > 4 else w[:-1]
    elif w.endswith("us") or w.endswith("ss"):
        pass
    elif w.endswith("s"):
        if any(_is_v(c) for c in w[:-2]):
            w = w[:-1]
    if w in _EXC2:
        return w
    # Step 1b
    done = False
    for s in ("eedly", "eed"):
        if w.endswith(s):
            if len(w) - len(s) >= r1:
                w = w[: -len(s)] + "ee"
            done = True
            break
    if not done:
        for s in ("ingly", "edly", "ing", "ed"):
            if w.endswith(s):
                stem = w[: -len(s)]
                if any(_is_v(c) for c in stem):
                    w = stem
                    if w.endswith(("at", "bl", "iz")):
                        w += "e"
                    elif w.endswith(_DOUBLES):
                        w = w[:-1]
                    elif _short_syllable_at_end(w) and r1 >= len(w):
                        w += "e"
                break
    # Step 1c
    if len(w) > 2 and w[-1] in "yY" and not _is_v(w[-2]):
        w = w[:-1] + "i"
    # Step 2
    step2 = [("ational", "ate"), ("tional", "tion"), ("enci", "ence"), ("anci", "ance"), ("abli", "able"),
             ("entli", "ent"), ("ization", "ize"), ("izer", "ize"), ("ation", "ate"), ("ator", "ate"), ("alism", "al"),
             ("aliti", "al"), ("alli", "al"), ("fulness", "ful"), ("ousli", "ous"), ("ousness", "ous"),
             ("iveness", "ive"), ("iviti", "ive"), ("biliti", "ble"), ("bli", "ble"), ("fulli", "ful"),
             ("lessli", "less"), ("ogi", "og"), ("li", "")]
    for s, rep in sorted(step2, key=lambda x: -len(x[0])):
        if w.endswith(s):
            if len(w) - len(s) >= r1:
                if s == "ogi":
                    if len(w) > 3 and w[-4] == "l":
                        w = w[:-3] + "og"
                elif s == "li":
                    if len(w) > 2 and w[-3] in _LI:
                        w = w[:-2]
                else:
                    w = w[: -len(s)] + rep
            break
    # Step 3
    step3 = [("ational", "ate"), ("tional", "tion"), ("alize", "al"), ("icate", "ic"), ("iciti", "ic"), ("ical", "ic"),
             ("ful", ""), ("ness", ""), ("ative", "")]
    for s, rep in sorted(step3, key=lambda x: -len(x[0])):
        if w.endswith(s):
            if len(w) - len(s) >= r1:
                if s == "ative":
                    if len(w) - len(s) >= r2:
                        w = w[: -len(s)]
                else:
                    w = w[: -len(s)] + rep
            break
    # Step 4
    step4 = ["al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment", "ent", "ism", "ate", "iti", "ous",
             "ive", "ize", "ion"]
    for s in sorted(step4, key=lambda x: -len(x)):
        if w.endswith(s):
            if len(w) - len(s) >= r2:
                if s == "ion":
                    if len(w) > 3 and w[-4] in "st":
                        w = w[:-3]
                else:
                    w = w[: -len(s)]
            break
    # Step 5
    if w.endswith("e"):
        if len(w) - 1 >= r2 or (len(w) - 1 >= r1 and not _short_syllable_at_end(w[:-1])):
            w = w[:-1]
    elif w.endswith("l"):
        if len(w) - 1 >= r2 and len(w) > 1 and w[-2] == "l":
            w = w[:-1]
    return w.replace("Y", "y")


# ---------------------------------------------------------------------------------------------------------------
# Question facts by rule (stage 3, no model): the names E and the predicate P.
def named_terms(q):
    """Port of `LibrarianState.namedTerms`: capitalised words not at a sentence start, letter-digit tokens."""
    words = [w for w in re.split(r"[ \n]", q.replace("’", "'")) if w]
    out = []
    for i, w in enumerate(words):
        core = re.sub(r"^[^\w]+|[^\w]+$|^_+|_+$", "", w).replace("'s", "")
        if len(core) < 2:
            continue
        at_start = i == 0 or (words[i - 1][-1:] in (".", "!", "?"))
        mixed = any(c.isalpha() for c in core) and any(c.isdigit() for c in core)
        if mixed or (not at_start and core[0].isupper() and core != "I"):
            out.append(core)
    return out


def quoted_phrases(s):
    closers = {'"': '"', "'": "'", "“": "”", "‘": "’"}
    out, i = [], 0
    while i < len(s):
        c = closers.get(s[i])
        if c is not None:
            j = s.find(c, i + 1)
            if j > i + 1:
                out.append(s[i + 1:j])
                i = j + 1
                continue
        i += 1
    return out


def names_and_predicate(q, tok):
    """E = the names (named terms + quoted titles) as tokens; P = the question's other content tokens."""
    e_words = named_terms(q) + [w for p in quoted_phrases(q) for w in p.split()]
    E = set(t for w in e_words for t in tok(w))
    P = [t for t in dict.fromkeys(tok(q)) if t not in E]
    return E, P, e_words


def strip_names(q):
    """The question with E's words removed (the S6e text to embed)."""
    e_words = named_terms(q) + [w for p in quoted_phrases(q) for w in p.split()]
    out = q
    for w in sorted(set(e_words), key=len, reverse=True):
        out = re.sub(r"(?<!\w)" + re.escape(w) + r"('s)?(?!\w)", " ", out)
    return re.sub(r"\s+", " ", out).strip()


def looks_like_ownership(q):
    """Port of `LibrarianState.looksLikeOwnershipQuestion` (the stopgap's gentler bar)."""
    ql = q.lower()
    return any(p in ql for p in ["my ", " mine", "i think", "i thought", "i believe", "i wrote", "i've written",
                                 "i have written", "i said", "i feel", "my own", "do i ", "did i ", "am i ",
                                 "have i ", "about me", "of mine"])


def common_english():
    p = HERE / "data" / "common-english-5000.txt"
    return {l.strip() for l in p.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")}


# ---------------------------------------------------------------------------------------------------------------
# Libraries: `nodes/<id>/{node.json, blocks.json, card.json}` as the app writes them.
@dataclass
class Library:
    name: str
    private: bool
    node_ids: list            # entry order
    titles: dict              # node -> title
    summaries: dict           # node -> summary
    p_node: list              # passage -> node
    p_block: list             # passage -> block id
    p_text: list              # passage -> text
    vecs: np.ndarray          # [passages, 384], unit length (zero rows stay zero)
    card_vecs: dict = field(default_factory=dict)   # node -> unit vector (the card / summary embedding)
    created: dict = field(default_factory=dict)
    source: str = ""

    @property
    def n(self):
        return len(self.p_text)


def _unit(m):
    m = np.asarray(m, dtype=np.float32)
    nrm = np.linalg.norm(m, axis=-1, keepdims=True)
    return np.where(nrm > 0, m / np.maximum(nrm, 1e-12), 0).astype(np.float32)


def load_library(nodes_dir, name, private=False, dim=384):
    """Read every entry in memory. Private entries (`is_private`) are left out, as the app's search does while hidden."""
    nodes_dir = Path(nodes_dir)
    if not nodes_dir.is_dir():
        raise SystemExit(f"{name}: no nodes folder at {'<fixture>' if private else nodes_dir}")
    wrap = Private if private else str
    ids, titles, summaries, created, cards = [], {}, {}, {}, {}
    pn, pb, pt, pv = [], [], [], []
    skipped_private = 0
    # The app's room rule (CorpusStore.corpusAskCandidateIDs → corpusRoomNodes = userNodesIncludingPrivate): once the
    # library holds an entry of the user's own, the seeded Sample Library (`sample_library.json` beside `nodes/`)
    # is left out of the search. Without this the fixture replay searched T's entries + the 210 sample entries and
    # C-a reproduced 1 / 17 (sweep 2b, 2026-11-23); with it 17 / 17.
    sample_ids, skipped_sample = set(), 0
    manifest = nodes_dir.parent / "sample_library.json"
    if manifest.is_file():
        try:
            sample_ids = set(json.loads(manifest.read_text(encoding="utf-8")).get("nodeIDs") or [])
        except Exception:
            sample_ids = set()
        dirs = [d.name for d in nodes_dir.iterdir() if (d / "node.json").is_file()]
        if not any(n not in sample_ids for n in dirs):
            sample_ids = set()   # only the Sample Library: the room keeps all of it
    for d in sorted(nodes_dir.iterdir()):
        nj = d / "node.json"
        if not nj.is_file():
            continue
        try:
            node = json.loads(nj.read_text(encoding="utf-8"))
        except Exception:
            continue
        nid = node.get("id") or d.name
        if nid in sample_ids or d.name in sample_ids:
            skipped_sample += 1
            continue
        if node.get("is_private"):
            skipped_private += 1
            continue
        ids.append(nid)
        titles[nid] = wrap(node.get("title") or "")
        summaries[nid] = wrap(node.get("summary") or "")
        created[nid] = node.get("created_at") or ""
        bj = d / "blocks.json"
        if bj.is_file():
            try:
                blocks = json.loads(bj.read_text(encoding="utf-8")).get("blocks", [])
            except Exception:
                blocks = []
            for b in sorted(blocks, key=lambda b: b.get("chunk_index", 0)):
                e = b.get("embedding") or []
                if len(e) != dim:
                    continue
                pn.append(nid); pb.append(b.get("block_id", "")); pt.append(wrap(b.get("text") or "")); pv.append(e)
        cj = d / "card.json"
        if cj.is_file():
            try:
                c = json.loads(cj.read_text(encoding="utf-8"))
                if len(c.get("embedding") or []) == dim:
                    cards[nid] = c["embedding"]
            except Exception:
                pass
    vecs = _unit(np.array(pv, dtype=np.float32)) if pv else np.zeros((0, dim), np.float32)
    cv = {k: _unit(np.array(v, dtype=np.float32)) for k, v in cards.items()}
    lib = Library(name, private, ids, titles, summaries, pn, pb, pt, vecs, cv, created,
                  source="<fixture>" if private else str(nodes_dir))
    lib.skipped_private = skipped_private
    lib.skipped_sample = skipped_sample
    return lib


def bench_key_map(lib, scratch_root=None):
    """bench `supports` keys -> node IDs: the scratch's `bench-notes.json` when there, else by planted title."""
    if scratch_root and (Path(scratch_root) / "bench-notes.json").is_file():
        return json.loads((Path(scratch_root) / "bench-notes.json").read_text())
    notes = json.loads((BENCHMARK / "notes.json").read_text(encoding="utf-8"))["notes"]
    by_title = {}
    for nid, t in lib.titles.items():
        by_title.setdefault(str(t), nid)
    return {n["key"]: by_title[n["title"]] for n in notes if n["title"] in by_title}


def sample_key_map(lib):
    """Sample `supports` keys are `title:<lowercased title>`."""
    out = {}
    for nid, t in lib.titles.items():
        out.setdefault("title:" + str(t).lower(), nid)
    return out
