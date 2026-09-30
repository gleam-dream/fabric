"""Faults at the actual byte-stream boundary, around the real counter service."""

import signal
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "examples"))
from counter_server import CounterService


class FaultService(CounterService):
    def __init__(self, database):
        super().__init__(database)
        self.held = {}

    def handle(self, request):
        method, request_id = request["method"], request.get("id")
        if method == "test/hold":
            name = request["params"]["name"]
            self.held[request_id] = name
            self.add(name, 1)
            return None
        if method == "notifications/cancelled":
            name = self.held.pop(request["params"]["requestId"], None)
            if name is not None:
                self.add(name + "/cancelled", 1)
                # A misbehaving peer can reply after cancellation. It must not
                # satisfy the next request on this still-open connection.
                self.send({"jsonrpc": "2.0", "id": request["params"]["requestId"], "result": {"late": True}})
            return None
        if method == "test/duplicate":
            print('{"jsonrpc":"2.0","id":%d,"result":{},"result":{"bad":true}}' % request_id, flush=True)
            return None
        if method == "test/wrong_id":
            self.send({"jsonrpc": "2.0", "id": request_id + 1, "result": {}})
            return None
        if method == "test/wrong_version":
            self.send({"jsonrpc": "1.0", "id": request_id, "result": {}})
            return None
        if method == "test/large":
            sys.stdout.write("x" * 2048)
            sys.stdout.flush()
            return None
        if method == "test/noise":
            for _ in range(10):
                self.send({"jsonrpc": "2.0", "method": "notifications/message", "params": {}})
            return {"result": {}}
        if method == "test/exit_after_effect":
            self.add(request["params"]["name"], 1)
            sys.exit(0)
        return super().handle(request)


if __name__ == "__main__":
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    FaultService(sys.argv[1]).serve()
