"""Independent protocol-fixture checks; these do not validate Jev inference."""

import http.client
import json
from pathlib import Path
import subprocess
import sys
import unittest
from urllib.parse import urlsplit


class FixtureTest(unittest.TestCase):
    def setUp(self):
        self.process = subprocess.Popen(
            [sys.executable, "-B", "-u", str(Path(__file__).with_name("server.py"))],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        endpoint = urlsplit(self.process.stdout.readline().strip())
        self.port = endpoint.port

    def tearDown(self):
        self.process.communicate("stop\n", timeout=5)
        self.assertEqual(self.process.returncode, 0)

    def post(self, path, data, key="test-key"):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request(
                "POST", path, json.dumps(data), {"Authorization": "Bearer " + key}
            )
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def request(self, state):
        return {
            "model": "fixture",
            "state": state,
            "questions": {
                "yes": {"type": "noul", "instructions": "correct?"},
                "route": {
                    "type": "choice",
                    "instructions": "choose",
                    "criteria": {"approve": "correct", "revise": "wrong"},
                },
                "quality": {
                    "type": "score",
                    "instructions": "rate",
                    "criteria": ["wrong", "partial", "correct"],
                },
            },
        }

    def test_all_question_shapes_and_requested_route(self):
        status, _, raw = self.post("/v1/systemone", self.request("fixture:revise"))
        self.assertEqual(status, 200)
        body = json.loads(raw)
        self.assertEqual(body["model"], "protocol-fixture-only")
        self.assertEqual(body["answers"]["route"]["choice"], "revise")
        self.assertEqual(
            body["answers"]["route"]["probabilities"], {"approve": 0.2, "revise": 0.8}
        )
        self.assertEqual(body["answers"]["yes"], {"type": "noul", "noul": 0.9})
        self.assertEqual(
            body["answers"]["quality"]["legend"],
            {"0": "wrong", "1": "partial", "2": "correct"},
        )
        self.assertEqual(body["answers"]["quality"]["score"], 1.8)
        self.assertEqual(body["usage"], {"input_tokens": 12, "output_tokens": 8})

    def test_rejection_redirect_and_retry_hint_are_observable(self):
        request = self.request("sample")
        self.assertEqual(self.post("/v1/systemone", request, "wrong-key")[0], 401)
        status, headers, _ = self.post("/redirect", request)
        self.assertEqual((status, headers["Location"]), (307, "/v1/systemone"))
        status, headers, body = self.post("/busy", request)
        self.assertEqual((status, headers["Retry-After"]), (429, "9"))
        self.assertIn(b"private diagnostic body", body)
        stats = json.loads(self.post("/stats", {})[2])
        self.assertEqual(stats["calls"], 2)
        self.assertEqual(stats["last_body"], request)

    def test_response_loss_is_an_incomplete_http_body(self):
        with self.assertRaises(http.client.IncompleteRead):
            self.post("/drop", self.request("sample"))
        self.assertEqual(json.loads(self.post("/stats", {})[2])["calls"], 1)


if __name__ == "__main__":
    unittest.main()
