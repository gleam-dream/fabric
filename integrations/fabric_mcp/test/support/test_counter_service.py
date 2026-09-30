"""Independent service acceptance; uses actual subprocess stdio and SQLite."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "examples"))
from counter_server import VERSION

SERVER = Path(__file__).resolve().parents[2] / "examples" / "counter_server.py"


def request(identity, method, **params):
    return {"jsonrpc": "2.0", "id": identity, "method": method, "params": {
        "_meta": {"io.modelcontextprotocol/protocolVersion": VERSION,
                  "io.modelcontextprotocol/clientCapabilities": {}}, **params}}


class ServiceTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = str(Path(self.directory.name) / "counter.sqlite")

    def tearDown(self):
        self.directory.cleanup()

    def run_requests(self, requests):
        process = subprocess.run([sys.executable, str(SERVER), self.database],
                                 input="".join(json.dumps(r) + "\n" for r in requests),
                                 capture_output=True, text=True, timeout=5, check=True)
        self.assertEqual(process.stderr, "")
        return [json.loads(line) for line in process.stdout.splitlines()]

    def test_effect_survives_eof_and_a_fresh_process(self):
        added = self.run_requests([request(1, "tools/call", name="counter/add", arguments={"name": "a", "amount": 4})])[0]
        self.assertEqual(added["result"]["structuredContent"], {"value": 4})
        read = self.run_requests([request(7, "tools/call", name="counter/read", arguments={"name": "a"})])[0]
        self.assertEqual(read["id"], 7)
        self.assertEqual(read["result"]["structuredContent"], {"value": 4})

    def test_discovery_and_complete_tool_contracts(self):
        discovery, tools = self.run_requests([request(1, "server/discover"), request(2, "tools/list")])
        self.assertEqual(discovery["result"]["supportedVersions"], [VERSION])
        self.assertEqual(tools["result"]["tools"][0]["inputSchema"]["required"], ["name", "amount"])
        self.assertEqual(tools["result"]["tools"][0]["outputSchema"]["required"], ["value"])

    def test_bad_inputs_and_legacy_metadata_cannot_change_counter(self):
        legacy = request(1, "tools/call", name="counter/add", arguments={"name": "a", "amount": 20})
        legacy["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] = "2024-11-05"
        bad, invalid, read = self.run_requests([
            legacy, request(2, "tools/call", name="counter/add", arguments={"name": "a", "amount": True}),
            request(3, "tools/call", name="counter/read", arguments={"name": "a"}),
        ])
        self.assertEqual(bad["error"]["code"], -32602)
        self.assertEqual(invalid["error"]["code"], -32602)
        self.assertEqual(read["result"]["structuredContent"], {"value": 0})

    def test_cancellation_is_a_notification_and_eof_exits(self):
        answers = self.run_requests([
            {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 3}},
            request(9, "server/discover"),
        ])
        self.assertEqual([answer["id"] for answer in answers], [9])


if __name__ == "__main__":
    unittest.main()
