#!/usr/bin/env python3
"""
Mock LLM name-extraction endpoint for the NER take-home.

    POST /v1/extract        body: {"prompt": "<text>"}

Responses:
    200  {"extractions": [{"name": "Maria", "start": 123, "end": 128}, ...],
          "usage": {"input_tokens": N}}
         Offsets are character offsets into the prompt you sent, so you can
         map results back to however you packed the request.
    400  {"error": "bad_request" | "request_too_large"}
    429  {"error": "rate_limit_exceeded"}   + Retry-After header (seconds)
    500  {"error": "internal_error"}        (injected at --error-rate;
                                             tokens are still consumed)

Token accounting: input_tokens = ceil(len(prompt) / 4).

Default limits are 1/100 of the production limits described in README.md,
so laptop-scale runs hit real 429s. The per-request cap is NOT scaled —
it's a shape constraint, not a throughput constraint.

    --tpm 40000                (production: 4,000,000 input tokens/min)
    --rpm 100                  (production: 10,000 requests/min)
    --max-request-tokens 8000  (production: 8,000)

Usage:
    python3 server.py [--port 8000] [--tpm 40000] [--rpm 100]
                      [--max-request-tokens 8000] [--error-rate 0.01]
                      [--min-latency 0.05] [--max-latency 0.3] [--quiet]

Python 3.8+, stdlib only. Do not modify for your submission (flags are fine).
"""

import argparse
import json
import math
import random
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIRST_NAMES = [
    "James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael", "Linda",
    "David", "Elizabeth", "William", "Barbara", "Richard", "Susan", "Joseph", "Jessica",
    "Thomas", "Sarah", "Charles", "Karen", "Christopher", "Lisa", "Daniel", "Nancy",
    "Matthew", "Betty", "Anthony", "Margaret", "Mark", "Sandra", "Donald", "Ashley",
    "Steven", "Kimberly", "Paul", "Emily", "Andrew", "Donna", "Joshua", "Michelle",
    "Kenneth", "Carol", "Kevin", "Amanda", "Brian", "Dorothy", "George", "Melissa",
    "Timothy", "Deborah",
    "Maria", "Jose", "Luis", "Carmen", "Miguel", "Rosa", "Juan", "Ana", "Carlos", "Sofia",
    "Wei", "Ming", "Chen", "Yuki", "Hiroshi", "Priya", "Raj", "Anil", "Deepa",
    "Fatima", "Omar", "Ahmed", "Layla", "Amara", "Kwame", "Chidi", "Ngozi",
    "Blessing", "Promise", "Precious", "Destiny", "Baptiste", "Colette", "Anders",
    "Ingrid", "Dmitri", "Svetlana", "Katya", "Giovanni", "Lucia", "Marco",
    "Aoife", "Siobhan", "Declan", "Grace", "Hope", "Faith", "Joy",
    "Sage", "River", "Winter", "Journey",
]

# Longest-first so e.g. a hypothetical "Ann" never shadows "Anna".
NAME_RE = re.compile(
    r"\b(?:" + "|".join(sorted(FIRST_NAMES, key=len, reverse=True)) + r")\b"
)


class Bucket:
    """Continuously-refilling token bucket."""

    def __init__(self, per_minute):
        self.capacity = float(per_minute)
        self.level = float(per_minute)
        self.rate = per_minute / 60.0
        self.last = time.monotonic()
        self.lock = threading.Lock()

    def _refill(self):
        now = time.monotonic()
        self.level = min(self.capacity, self.level + (now - self.last) * self.rate)
        self.last = now

    def take(self, n):
        """Returns (ok, retry_after_seconds)."""
        with self.lock:
            self._refill()
            if self.level >= n:
                self.level -= n
                return True, 0
            return False, max(1, math.ceil((n - self.level) / self.rate))

    def refund(self, n):
        with self.lock:
            self.level = min(self.capacity, self.level + n)


ARGS = None
REQ_BUCKET = None
TOK_BUCKET = None
RNG = random.Random()


class Handler(BaseHTTPRequestHandler):
    server_version = "MockLLM/1.0"

    def _send(self, status, payload, headers=None):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/v1/extract":
            self._send(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length))
            prompt = payload["prompt"]
            assert isinstance(prompt, str) and prompt
        except Exception:
            self._send(400, {"error": "bad_request",
                             "detail": 'expected JSON body {"prompt": "<text>"}'})
            return

        tokens = math.ceil(len(prompt) / 4)
        if tokens > ARGS.max_request_tokens:
            self._send(400, {"error": "request_too_large",
                             "detail": f"{tokens} tokens > "
                                       f"{ARGS.max_request_tokens} max per request"})
            return

        ok, retry = REQ_BUCKET.take(1)
        if not ok:
            self._send(429, {"error": "rate_limit_exceeded", "limit": "requests"},
                       {"Retry-After": str(retry)})
            return
        ok, retry = TOK_BUCKET.take(tokens)
        if not ok:
            REQ_BUCKET.refund(1)
            self._send(429, {"error": "rate_limit_exceeded", "limit": "tokens"},
                       {"Retry-After": str(retry)})
            return

        time.sleep(RNG.uniform(ARGS.min_latency, ARGS.max_latency))

        if RNG.random() < ARGS.error_rate:
            self._send(500, {"error": "internal_error"})
            return

        extractions = [{"name": m.group(0), "start": m.start(), "end": m.end()}
                       for m in NAME_RE.finditer(prompt)]
        self._send(200, {"extractions": extractions,
                         "usage": {"input_tokens": tokens}})

    def log_message(self, fmt, *args):
        if not ARGS.quiet:
            super().log_message(fmt, *args)


def main():
    global ARGS, REQ_BUCKET, TOK_BUCKET
    p = argparse.ArgumentParser(description="Mock LLM extraction endpoint")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--tpm", type=int, default=40000, help="input tokens per minute")
    p.add_argument("--rpm", type=int, default=100, help="requests per minute")
    p.add_argument("--max-request-tokens", type=int, default=8000)
    p.add_argument("--error-rate", type=float, default=0.01)
    p.add_argument("--min-latency", type=float, default=0.05)
    p.add_argument("--max-latency", type=float, default=0.3)
    p.add_argument("--seed", type=int, help="seed error/latency randomness")
    p.add_argument("--quiet", action="store_true")
    ARGS = p.parse_args()

    if ARGS.seed is not None:
        RNG.seed(ARGS.seed)
    REQ_BUCKET = Bucket(ARGS.rpm)
    TOK_BUCKET = Bucket(ARGS.tpm)

    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print(f"mock LLM listening on http://127.0.0.1:{ARGS.port} "
          f"(tpm={ARGS.tpm}, rpm={ARGS.rpm}, "
          f"max_request_tokens={ARGS.max_request_tokens}, "
          f"error_rate={ARGS.error_rate})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
