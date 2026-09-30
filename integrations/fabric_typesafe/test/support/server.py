"""A loopback TypeSafe protocol fixture. It does not run a classifier model."""

import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Fixture(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.calls = 0
        self.disconnected = 0
        self.last_body = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, code, body, extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/stats":
            with self.server.lock:
                data = {"calls": self.server.calls, "disconnected": self.server.disconnected, "last_body": self.server.last_body}
            self.reply(200, data)
            return
        if self.headers.get("Authorization") != "Bearer test-key":
            self.reply(401, {"error": "invalid fixture key"})
            return
        request = json.loads(raw)
        with self.server.lock:
            self.server.calls += 1
            self.server.last_body = request
        try:
            if self.path == "/hold":
                self.connection.settimeout(5)
                if self.connection.recv(1) == b"":
                    with self.server.lock:
                        self.server.disconnected += 1
                self.close_connection = True
                return
            if self.path == "/drop":
                self.send_response(200)
                self.send_header("Content-Length", "10000")
                self.end_headers()
                self.wfile.write(b'{"model":')
                self.wfile.flush()
                self.close_connection = True
                return
            if self.path == "/large":
                self.reply(200, b"x" * 4096)
                return
            if self.path == "/headers":
                self.reply(200, {}, {"X-Long": "x" * 4096})
                return
            if self.path == "/redirect":
                self.reply(307, {}, {"Location": "/v1/systemone"})
                return
            if self.path == "/busy":
                self.reply(429, {"error": "private diagnostic body"}, {"Retry-After": "9"})
                return
            if self.path == "/duplicate":
                self.reply(200, b'{"model":"one","model":"two","answers":{},"usage":{}}')
                return
            result = evaluate_fixture(request)
            if self.path == "/wrong":
                result["answers"] = {"unrequested": {"type": "noul", "noul": 1}}
            self.reply(200, result)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True


def evaluate_fixture(request):
    answers = {}
    state = request["state"]
    wanted = state.get("fixture_choice") if isinstance(state, dict) else None
    if isinstance(state, str) and state.startswith("fixture:"):
        wanted = state.removeprefix("fixture:")
    for identity, question in request["questions"].items():
        kind = question["type"]
        if kind == "noul":
            answers[identity] = {"type": kind, "noul": 0.9}
        elif kind == "choice":
            labels = list(question["criteria"])
            selected = wanted if wanted in labels else labels[0]
            others = [label for label in labels if label != selected]
            probabilities = {label: 0.0 for label in labels}
            probabilities[selected] = 0.8
            probabilities[others[0]] = 0.2
            answers[identity] = {"type": kind, "choice": selected, "probabilities": probabilities, "confidence": 0.7}
        elif kind == "score":
            levels = question["criteria"]
            probabilities = {str(i): 0.0 for i in range(len(levels))}
            probabilities[str(len(levels) - 1)] = 0.8
            probabilities[str(len(levels) - 2)] = 0.2
            answers[identity] = {"type": kind, "score": len(levels) - 1.2, "probabilities": probabilities,
                                 "legend": {str(i): level for i, level in enumerate(levels)}, "confidence": 0.7}
    return {"model": "protocol-fixture-only", "answers": answers, "usage": {"input_tokens": 12, "output_tokens": 8}}


if __name__ == "__main__":
    service = Fixture()
    worker = threading.Thread(target=service.serve_forever, daemon=True)
    worker.start()
    print(f"http://127.0.0.1:{service.server_port}", flush=True)
    sys.stdin.readline()
    service.shutdown()
    service.server_close()
    print("stopped", flush=True)
