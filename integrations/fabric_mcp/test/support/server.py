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
        self.mode = "normal"

    def handle(self, request):
        method, request_id = request["method"], request.get("id")
        if method == "test/config":
            self.mode = request["params"]["mode"]
            return {"result": {}}
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
        answer = super().handle(request)
        if method == "server/discover" and self.mode == "legacy":
            answer["result"]["supportedVersions"] = ["2024-11-05"]
        if method == "tools/list":
            tools = answer["result"]["tools"]
            if self.mode in ("no_output", "text_only"):
                tools[0].pop("outputSchema")
            if self.mode == "description":
                tools[0]["inputSchema"]["description"] = "An updated explanation"
            if self.mode == "drift":
                tools[0]["inputSchema"]["properties"]["amount"] = {"type": "string"}
            if self.mode == "open_schema":
                tools[0]["inputSchema"].pop("additionalProperties")
            if self.mode == "legacy_dialect":
                tools[0]["inputSchema"]["$schema"] = "http://json-schema.org/draft-07/schema#"
            if self.mode == "reference_schema":
                tools[0]["inputSchema"]["$ref"] = "https://example.invalid/schema"
            if self.mode == "duplicate":
                tools.append(tools[0])
            if self.mode == "pages":
                if request["params"].get("cursor") == "second":
                    answer["result"]["tools"] = [tools[0]]
                else:
                    answer["result"]["tools"] = [tools[1]]
                    answer["result"]["nextCursor"] = "second"
            if self.mode == "cursor_loop":
                answer["result"]["tools"] = []
                answer["result"]["nextCursor"] = "again"
        if method == "tools/call" and request["params"].get("name") == "counter/add":
            if self.mode == "bad_output":
                answer["result"]["structuredContent"] = {"value": "wrong"}
            if self.mode == "tool_error":
                answer["result"]["isError"] = True
            if self.mode == "rpc_error":
                answer = {"error": {"code": -32603, "message": "reply lost after effect", "data": {"committed": True}}}
            if self.mode == "input_required":
                answer["result"]["resultType"] = "input_required"
            if self.mode == "bad_content":
                answer["result"]["content"] = [42]
            if self.mode == "missing_structured":
                answer["result"].pop("structuredContent")
            if self.mode == "text_only":
                answer["result"].pop("structuredContent")
            if self.mode == "implicit_complete":
                answer["result"].pop("resultType")
            if self.mode == "all_content":
                answer["result"]["content"].extend([
                    {"type": "image", "data": "AA==", "mimeType": "image/png"},
                    {"type": "audio", "data": "AA==", "mimeType": "audio/wav"},
                    {"type": "resource_link", "uri": "counter://value", "name": "value"},
                    {"type": "resource", "resource": {"uri": "counter://text", "text": "retained text"}},
                    {"type": "resource", "resource": {"uri": "counter://blob", "blob": "AA=="}},
                ])
            if self.mode == "exit":
                sys.exit(0)
            if self.mode == "hold":
                self.held[request_id] = request["params"]["arguments"]["name"]
                return None
        return answer


if __name__ == "__main__":
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    FaultService(sys.argv[1]).serve()
