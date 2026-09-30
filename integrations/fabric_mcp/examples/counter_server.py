"""A small MCP 2026-07-28 stdio service with real SQLite-backed effects.

Run with a database path. Each process shares the same durable counter store;
closing stdin closes the service. There is deliberately no automatic deduplication.
"""

import json
import sqlite3
import sys

VERSION = "2026-07-28"


class CounterService:
    def __init__(self, database):
        self.database = database
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL)")

    def connect(self):
        return sqlite3.connect(self.database, timeout=5)

    def add(self, name, amount):
        with self.connect() as db:
            db.execute(
                "INSERT INTO counters VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value=value+excluded.value",
                (name, amount),
            )
            return db.execute("SELECT value FROM counters WHERE name=?", (name,)).fetchone()[0]

    def read(self, name):
        with self.connect() as db:
            row = db.execute("SELECT value FROM counters WHERE name=?", (name,)).fetchone()
            return row[0] if row else 0

    def handle(self, request):
        method, params = request["method"], request.get("params", {})
        if method == "notifications/cancelled":
            return None
        meta = params.get("_meta", {})
        if meta.get("io.modelcontextprotocol/protocolVersion") != VERSION:
            return {"error": {"code": -32602, "message": "unsupported protocol version"}}
        if not isinstance(meta.get("io.modelcontextprotocol/clientCapabilities"), dict):
            return {"error": {"code": -32602, "message": "missing capabilities"}}
        if method == "server/discover":
            return {"result": {
                "resultType": "complete", "supportedVersions": [VERSION],
                "capabilities": {"tools": {}},
                "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "fabric-counter", "version": "1"}},
            }}
        if method == "tools/list":
            return {"result": {"resultType": "complete", "tools": [
                {"name": "counter/add", "inputSchema": object_schema({"name": {"type": "string"}, "amount": {"type": "integer"}}),
                 "outputSchema": object_schema({"value": {"type": "integer"}})},
                {"name": "counter/read", "inputSchema": object_schema({"name": {"type": "string"}}),
                 "outputSchema": object_schema({"value": {"type": "integer"}})},
            ]}}
        if method == "tools/call":
            tool, args = params.get("name"), params.get("arguments", {})
            if tool not in ("counter/add", "counter/read") or not isinstance(args, dict):
                return {"error": {"code": -32602, "message": "unknown tool or invalid arguments"}}
            expected = {"name", "amount"} if tool == "counter/add" else {"name"}
            if set(args) != expected or not isinstance(args.get("name"), str):
                return {"error": {"code": -32602, "message": "invalid counter arguments"}}
            if tool == "counter/add" and type(args["amount"]) is not int:
                return {"error": {"code": -32602, "message": "amount must be an integer"}}
            answer = self.add(args["name"], args["amount"]) if tool == "counter/add" else self.read(args["name"])
            return {"result": {"resultType": "complete", "content": [{"type": "text", "text": str(answer)}],
                               "structuredContent": {"value": answer}, "isError": False}}
        return {"error": {"code": -32601, "message": "method not found", "data": {"method": method}}}

    def serve(self):
        for line in sys.stdin:
            request = json.loads(line)
            payload = self.handle(request)
            if payload is not None and "id" in request:
                self.send({"jsonrpc": "2.0", "id": request["id"], **payload})

    @staticmethod
    def send(message):
        print(json.dumps(message, separators=(",", ":")), flush=True)


def object_schema(properties):
    return {"type": "object", "properties": properties, "required": list(properties), "additionalProperties": False}


if __name__ == "__main__":
    CounterService(sys.argv[1]).serve()
