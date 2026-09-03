#!/usr/bin/env python3
"""Tiny relay proxy between BFCL and llama-swap (issue #29, part of #28).

BFCL's local-inference handler hard-codes the "model" field it sends in
every request to either a local filesystem path (when --local-model-path
is used) or its own internal handler name (e.g.
"meta-llama/Llama-3.1-8B-Instruct-FC") — neither matches the model ID
this deployment's llama-swap actually routes on (e.g.
"llama-3.1-8b-instruct"). There's no BFCL flag to override this (checked
its source directly, not assumed — see shared/model-evaluation.md).

This proxy sits between BFCL and llama-swap: it rewrites the "model"
field in every JSON request body to the real model ID before forwarding,
so neither BFCL nor llama-swap's own config needs to change.
"""
import argparse
import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class ProxyHandler(BaseHTTPRequestHandler):
    upstream_base_url = None
    real_model_id = None
    # BFCL's local-inference path fires up to 100 concurrent requests
    # (hard-coded ThreadPoolExecutor(max_workers=100) in its own source,
    # not affected by any BFCL CLI flag) — real vLLM/SGLang servers
    # handle that via continuous batching, but a single llama-server
    # instance serving one model does not, and returns 429 for anything
    # beyond one in flight. Found live-testing this proxy: without this
    # lock, nearly every request came back 429. Serializing here (rather
    # than changing the real deployment's llama-server concurrency flags)
    # keeps eval traffic from affecting production serving behavior.
    inference_lock = threading.Lock()

    def _proxy(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length else b""
        serialize = self.path.startswith("/v1/completions") or self.path.startswith(
            "/v1/chat/completions"
        )
        if serialize:
            self.inference_lock.acquire()
        try:
            self._forward(body)
        finally:
            if serialize:
                self.inference_lock.release()

    def _forward(self, body):

        if body:
            try:
                payload = json.loads(body)
                if isinstance(payload, dict) and "model" in payload:
                    payload["model"] = self.real_model_id
                body = json.dumps(payload).encode()
            except json.JSONDecodeError:
                pass  # non-JSON body (shouldn't happen here) — forward as-is

        req = urllib.request.Request(
            f"{self.upstream_base_url}{self.path}",
            data=body if body else None,
            method=self.command,
        )
        for header, value in self.headers.items():
            if header.lower() not in ("host", "content-length"):
                req.add_header(header, value)
        if body:
            req.add_header("Content-Length", str(len(body)))

        try:
            with urllib.request.urlopen(req, timeout=72000) as resp:
                self.send_response(resp.status)
                for header, value in resp.getheaders():
                    if header.lower() not in ("transfer-encoding", "connection"):
                        self.send_header(header, value)
                self.end_headers()
                self.wfile.write(resp.read())
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            body = e.read()
            for header, value in e.headers.items():
                if header.lower() not in ("transfer-encoding", "connection"):
                    self.send_header(header, value)
            self.end_headers()
            self.wfile.write(body)

    def do_GET(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def log_message(self, format, *args):
        sys.stderr.write(f"[model-alias-proxy] {self.address_string()} {format % args}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-host", required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--real-model-id", required=True)
    args = parser.parse_args()

    ProxyHandler.upstream_base_url = f"http://{args.upstream_host}:{args.upstream_port}"
    ProxyHandler.real_model_id = args.real_model_id

    server = ThreadingHTTPServer(("127.0.0.1", args.listen_port), ProxyHandler)
    print(
        f"[model-alias-proxy] listening on 127.0.0.1:{args.listen_port}, "
        f"forwarding to {ProxyHandler.upstream_base_url}, "
        f"aliasing every request's model to '{args.real_model_id}'",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
