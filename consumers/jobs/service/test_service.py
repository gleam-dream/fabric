"""Service boundary checks, including loss of the independent server process."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


@contextmanager
def service(directory: Path) -> Iterator[str]:
    ready = directory / "ready"
    ready.unlink(missing_ok=True)
    with (directory / "server.log").open("ab") as log:
        process = subprocess.Popen([
            sys.executable, str(Path(__file__).with_name("server.py")),
            "--directory", str(directory / "jobs"), "--ready-file", str(ready),
        ], stdout=log, stderr=log)
        try:
            for _ in range(200):
                if process.poll() is not None:
                    raise RuntimeError("server exited during startup")
                if ready.exists():
                    yield ready.read_text(encoding="utf-8")
                    break
                time.sleep(0.01)
            else:
                raise RuntimeError("server startup timed out")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def request(url: str, body: object | None = None) -> tuple[int, object]:
    data = None if body is None else json.dumps(body).encode()
    message = Request(url, data, headers={"Content-Type": "application/json"})
    try:
        with urlopen(message, timeout=3) as reply:
            return reply.status, json.load(reply)
    except HTTPError as error:
        with error:
            return error.code, json.load(error)


class ServiceTests(unittest.TestCase):
    def test_queued_acceptance_and_result_survive_service_restart(self) -> None:
        submission = {"key": "durable-key", "text": "retained job", "delay_ms": 1000}
        with tempfile.TemporaryDirectory(prefix="fabric-job-service-") as path:
            directory = Path(path)
            with service(directory) as url:
                status, receipt = request(url + "/jobs", submission)
                self.assertEqual(status, 202)
                assert isinstance(receipt, dict)
                job_id = receipt["id"]
                self.assertEqual(request(url + "/jobs/" + job_id)[1], {
                    "id": job_id, "state": "queued", "digest": None,
                })
            # A fresh OS process opens the existing journal and owns the work.
            with service(directory) as url:
                self.assertEqual(request(url + "/jobs", submission), (202, receipt))
                self.assertEqual(request(url + "/count"), (200, {"count": 1}))
                for _ in range(200):
                    _, progress = request(url + "/jobs/" + job_id)
                    assert isinstance(progress, dict)
                    if progress["state"] == "complete":
                        break
                    time.sleep(0.01)
                else:
                    self.fail("retained job did not complete")
                self.assertEqual(request(url + "/jobs/" + job_id + "/artifact"), (200, "RETAINED JOB"))
            with service(directory) as url:
                self.assertEqual(request(url + "/jobs/" + job_id)[1], progress)
                self.assertEqual(request(url + "/jobs/" + job_id + "/artifact"), (200, "RETAINED JOB"))

    def test_invalid_requests_are_refused_before_acceptance(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fabric-job-service-") as path:
            with service(Path(path)) as url:
                for body in [[], {}, {"key": "x", "text": "x", "delay_ms": True}, {"key": "x", "text": "x", "delay_ms": -1}]:
                    self.assertEqual(request(url + "/jobs", body)[0], 400)
                self.assertEqual(request(url + "/count"), (200, {"count": 0}))


if __name__ == "__main__":
    unittest.main()
