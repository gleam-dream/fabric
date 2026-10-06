"""Service boundary checks, including loss of the independent server process."""

from __future__ import annotations

import json
import sqlite3
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from collections.abc import Iterator
from contextlib import ExitStack, contextmanager
from pathlib import Path
from http.server import BaseHTTPRequestHandler
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server import JobHTTPServer, Jobs, Submission


@contextmanager
def service(directory: Path) -> Iterator[str]:
    ready = directory / "ready"
    ready.unlink(missing_ok=True)
    with (directory / "server.log").open("ab") as log:
        process = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).with_name("server.py")),
                "--directory",
                str(directory / "jobs"),
                "--ready-file",
                str(ready),
            ],
            stdout=log,
            stderr=log,
        )
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
    def test_listen_queue_admits_eight_connections_before_accept(self) -> None:
        # The same burst the Gleam consumer submits must fit while accept is busy.
        with JobHTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler) as server:
            with ExitStack() as connections:
                for _ in range(8):
                    connections.enter_context(
                        socket.create_connection(server.server_address, timeout=0.2)
                    )

    def test_cancellation_upgrade_preserves_the_legacy_job_journal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fabric-job-upgrade-") as path:
            directory = Path(path)
            with sqlite3.connect(directory / "jobs.sqlite") as db:
                db.execute("""CREATE TABLE jobs (
                    id TEXT PRIMARY KEY, submission_key TEXT NOT NULL UNIQUE,
                    text TEXT NOT NULL, delay_ms INTEGER NOT NULL, due REAL NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('queued', 'complete')), digest TEXT
                )""")
                db.execute(
                    "INSERT INTO jobs VALUES (?,?,?,?,?,?,?)",
                    ("a" * 64, "queued-key", "queued", 0, 0, "queued", None),
                )
                db.execute(
                    "INSERT INTO jobs VALUES (?,?,?,?,?,?,?)",
                    (
                        "b" * 64,
                        "completed-key",
                        "completed",
                        0,
                        0,
                        "complete",
                        "c" * 64,
                    ),
                )
            jobs = Jobs(directory)
            jobs = Jobs(directory)  # Repeated startup does not migrate again.
            self.assertEqual(jobs.count(), 2)
            self.assertEqual(
                jobs.request_cancel("a" * 64),
                {"id": "a" * 64, "state": "cancel_requested"},
            )
            self.assertEqual(
                jobs.request_cancel("b" * 64),
                {"id": "b" * 64, "state": "complete", "digest": "c" * 64},
            )

    def test_cancel_request_is_retained_before_confirmation_and_survives_restart(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="fabric-job-cancel-") as path:
            directory = Path(path)
            journal = directory / "jobs"
            jobs = Jobs(journal)
            job_id = jobs.submit(Submission("cancel-on-restart", "must not publish", 0))
            # A process may die after writing an artifact but before recording
            # completion. Cancellation must settle this residue before confirming.
            (journal / (job_id + ".txt")).write_text("UNCOMMITTED", encoding="utf-8")
            accepted = {"id": job_id, "state": "cancel_requested"}
            self.assertEqual(jobs.request_cancel(job_id), accepted)
            self.assertEqual(Jobs(journal).get(job_id), {**accepted, "digest": None})
            with service(directory) as url:
                self.assertEqual(
                    request(url + "/jobs/" + job_id + "/cancel", {}), (202, accepted)
                )
                progress = self.await_terminal(url, job_id)
                self.assertEqual(progress["state"], "cancelled")
                self.assertEqual(request(url + "/jobs/" + job_id + "/artifact")[0], 404)
                self.assertFalse((journal / (job_id + ".txt")).exists())
            with service(directory) as url:
                self.assertEqual(request(url + "/jobs/" + job_id)[1], progress)
                self.assertEqual(
                    request(url + "/jobs/" + job_id + "/cancel", {}), (202, accepted)
                )

    @staticmethod
    def await_terminal(url: str, job_id: str) -> dict[str, object]:
        for _ in range(300):
            _, progress = request(url + "/jobs/" + job_id)
            assert isinstance(progress, dict)
            if progress["state"] in {"complete", "cancelled"}:
                return progress
            time.sleep(0.01)
        raise AssertionError("job did not settle")

    def test_stop_and_artifact_publication_have_one_winner(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fabric-job-cancel-") as path:
            with service(Path(path)) as url:

                def race(n: int) -> None:
                    _, receipt = request(
                        url + "/jobs",
                        {"key": "race-" + str(n), "text": "race", "delay_ms": n % 3},
                    )
                    assert isinstance(receipt, dict)
                    job_id = str(receipt["id"])
                    status, acknowledgment = request(
                        url + "/jobs/" + job_id + "/cancel", {}
                    )
                    progress = self.await_terminal(url, job_id)
                    if status == 202:
                        self.assertEqual(
                            acknowledgment, {"id": job_id, "state": "cancel_requested"}
                        )
                        self.assertEqual(progress["state"], "cancelled")
                        self.assertEqual(
                            request(url + "/jobs/" + job_id + "/artifact")[0], 404
                        )
                    else:
                        self.assertEqual(status, 200)
                        self.assertEqual(acknowledgment, progress)
                        self.assertEqual(progress["state"], "complete")
                        self.assertEqual(
                            request(url + "/jobs/" + job_id + "/artifact"),
                            (200, "RACE"),
                        )
                    self.assertEqual(
                        request(url + "/jobs/" + job_id + "/cancel", {}),
                        (status, acknowledgment),
                    )

                with ThreadPoolExecutor(max_workers=4) as pool:
                    list(pool.map(race, range(16)))
                self.assertEqual(
                    request(url + "/jobs/" + "f" * 64 + "/cancel", {})[0], 404
                )

    def test_queued_acceptance_and_result_survive_service_restart(self) -> None:
        submission = {"key": "durable-key", "text": "retained job", "delay_ms": 1000}
        with tempfile.TemporaryDirectory(prefix="fabric-job-service-") as path:
            directory = Path(path)
            with service(directory) as url:
                status, receipt = request(url + "/jobs", submission)
                self.assertEqual(status, 202)
                assert isinstance(receipt, dict)
                job_id = receipt["id"]
                self.assertEqual(
                    request(url + "/jobs/" + job_id)[1],
                    {
                        "id": job_id,
                        "state": "queued",
                        "digest": None,
                    },
                )
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
                self.assertEqual(
                    request(url + "/jobs/" + job_id + "/artifact"),
                    (200, "RETAINED JOB"),
                )
            with service(directory) as url:
                self.assertEqual(request(url + "/jobs/" + job_id)[1], progress)
                self.assertEqual(
                    request(url + "/jobs/" + job_id + "/artifact"),
                    (200, "RETAINED JOB"),
                )

    def test_invalid_requests_are_refused_before_acceptance(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fabric-job-service-") as path:
            with service(Path(path)) as url:
                for body in [
                    [],
                    {},
                    {"key": "x", "text": "x", "delay_ms": True},
                    {"key": "x", "text": "x", "delay_ms": -1},
                ]:
                    self.assertEqual(request(url + "/jobs", body)[0], 400)
                self.assertEqual(request(url + "/count"), (200, {"count": 0}))
                _, receipt = request(
                    url + "/jobs",
                    {"key": "invalid-stop", "text": "untouched", "delay_ms": 5000},
                )
                assert isinstance(receipt, dict)
                stop_url = url + "/jobs/" + str(receipt["id"]) + "/cancel"
                self.assertEqual(request(stop_url, {"unexpected": True})[0], 400)
                _, progress = request(url + "/jobs/" + str(receipt["id"]))
                assert isinstance(progress, dict)
                self.assertEqual(progress["state"], "queued")


if __name__ == "__main__":
    unittest.main()
