"""Local durable artifact jobs for Fabric's external submission example.

The service owns its SQLite journal and work. Clients submit, observe and request
cancellation. Stop acceptance and terminal cancellation are separate facts.
Run with --directory PATH --ready-file PATH; bind an ephemeral loopback port.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


@dataclass(frozen=True)
class Submission:
    key: str
    text: str
    delay_ms: int

    @staticmethod
    def parse(value: object) -> Submission:
        if not isinstance(value, dict) or set(value) != {"key", "text", "delay_ms"}:
            raise ValueError("expected key, text and delay_ms")
        key, text, delay = value["key"], value["text"], value["delay_ms"]
        if not isinstance(key, str) or not 1 <= len(key) <= 1024:
            raise ValueError("invalid submission key")
        if not isinstance(text, str) or len(text.encode()) > 65536:
            raise ValueError("invalid artifact text")
        if type(delay) is not int or not 0 <= delay <= 5000:
            raise ValueError("delay_ms must be an integer between 0 and 5000")
        return Submission(key, text, delay)


class Conflict(Exception):
    """A key already names a different request."""


class Jobs:
    def __init__(self, directory: Path):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.database = directory / "jobs.sqlite"
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            version = int(db.execute("PRAGMA user_version").fetchone()[0])
            if version > 1:
                raise ValueError("unsupported job journal version")
            if version == 1:
                return
            legacy = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='jobs'").fetchone() is not None
            if legacy:
                db.execute("ALTER TABLE jobs RENAME TO jobs_legacy")
            db.execute("""CREATE TABLE jobs (
                id TEXT PRIMARY KEY, submission_key TEXT NOT NULL UNIQUE,
                text TEXT NOT NULL, delay_ms INTEGER NOT NULL, due REAL NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('queued', 'complete', 'cancel_requested', 'cancelled')),
                digest TEXT
            )""")
            if legacy:
                db.execute("INSERT INTO jobs SELECT * FROM jobs_legacy")
                db.execute("DROP TABLE jobs_legacy")
            db.execute("PRAGMA user_version=1")

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.database, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def submit(self, request: Submission) -> str:
        with self.connect() as db:
            # Serialize key comparison and acceptance; reply only after commit.
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM jobs WHERE submission_key=?", (request.key,)).fetchone()
            if row is not None:
                if row["text"] != request.text or row["delay_ms"] != request.delay_ms:
                    raise Conflict("submission key already binds different input")
                return str(row["id"])
            identifier = hashlib.sha256(request.key.encode()).hexdigest()
            db.execute("INSERT INTO jobs VALUES (?,?,?,?,?,'queued',NULL)", (
                identifier, request.key, request.text, request.delay_ms,
                time.time() + request.delay_ms / 1000,
            ))
        return identifier

    def get(self, identifier: str) -> dict[str, object] | None:
        with self.connect() as db:
            row = db.execute("SELECT id,state,digest FROM jobs WHERE id=?", (identifier,)).fetchone()
        return dict(row) if row is not None else None

    def request_cancel(self, identifier: str) -> dict[str, object] | None:
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT id,state,digest FROM jobs WHERE id=?", (identifier,)).fetchone()
            if row is None:
                return None
            if row["state"] == "complete":
                return dict(row)
            if row["state"] == "queued":
                db.execute("UPDATE jobs SET state='cancel_requested' WHERE id=?", (identifier,))
            # Return the same acceptance fact even if its worker already
            # confirmed cancellation. A duplicate never creates new work.
            return {"id": identifier, "state": "cancel_requested"}

    def count(self) -> int:
        with self.connect() as db:
            return int(db.execute("SELECT count(*) FROM jobs").fetchone()[0])

    def artifact(self, identifier: str) -> str | None:
        row = self.get(identifier)
        if row is None or row["state"] != "complete":
            return None
        return (self.directory / (identifier + ".txt")).read_text(encoding="utf-8")

    def process_due(self) -> None:
        # One service worker owns artifact writes. A crash before completion
        # leaves the job queued; writing the same deterministic artifact is safe.
        with self.connect() as db:
            rows = db.execute("SELECT id FROM jobs WHERE state='cancel_requested' OR (state='queued' AND due<=?)", (time.time(),)).fetchall()
        for row in rows:
            # Stop admission and publication serialize through the same lock.
            # Re-read after acquiring it: the earlier due list is only a hint.
            with self.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                current = db.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone()
                if current["state"] in {"complete", "cancelled"}:
                    continue
                destination = self.directory / (row["id"] + ".txt")
                temporary = destination.with_suffix(".pending")
                if current["state"] == "cancel_requested":
                    # Remove unpublished residue from an interrupted write
                    # before confirming that cancellation has settled.
                    temporary.unlink(missing_ok=True)
                    destination.unlink(missing_ok=True)
                    self.sync_directory()
                    db.execute("UPDATE jobs SET state='cancelled' WHERE id=?", (row["id"],))
                    continue
                content = str(current["text"]).upper().encode()
                with temporary.open("wb") as output:
                    output.write(content)
                    output.flush()
                    os.fsync(output.fileno())
                temporary.replace(destination)
                self.sync_directory()
                db.execute("UPDATE jobs SET state='complete',digest=? WHERE id=?", (
                    hashlib.sha256(content).hexdigest(), row["id"],
                ))

    def sync_directory(self) -> None:
        directory = os.open(self.directory, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def serve(directory: Path, ready_file: Path) -> None:
    jobs = Jobs(directory)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *args: object) -> None:
            pass

        def reply(self, status: int, value: object) -> None:
            encoded = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_POST(self) -> None:
            parts = self.path.split("/")
            if len(parts) == 4 and parts[1] == "jobs" and parts[3] == "cancel":
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if not 0 < length <= 1024 or json.loads(self.rfile.read(length)) != {}:
                        raise ValueError("cancellation requires an empty object")
                except (ValueError, UnicodeDecodeError) as error:
                    self.reply(400, {"error": str(error)})
                    return
                progress = jobs.request_cancel(parts[2])
                if progress is None:
                    self.reply(404, {"error": "not found"})
                else:
                    self.reply(200 if progress["state"] == "complete" else 202, progress)
                return
            if self.path != "/jobs":
                self.reply(404, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 131072:
                    raise ValueError("invalid body length")
                request = Submission.parse(json.loads(self.rfile.read(length)))
                identifier = jobs.submit(request)
            except (ValueError, UnicodeDecodeError) as error:
                self.reply(400, {"error": str(error)})
            except Conflict as error:
                self.reply(409, {"error": str(error)})
            else:
                self.reply(202, {"id": identifier})

        def do_GET(self) -> None:
            if self.path == "/count":
                self.reply(200, {"count": jobs.count()})
                return
            parts = self.path.split("/")
            if len(parts) not in (3, 4) or parts[1] != "jobs":
                self.reply(404, {"error": "not found"})
                return
            identifier = parts[2]
            value = jobs.get(identifier) if len(parts) == 3 else (
                jobs.artifact(identifier) if parts[3] == "artifact" else None
            )
            self.reply(404 if value is None else 200, value)

    stop = threading.Event()

    def work() -> None:
        while not stop.wait(0.02):
            jobs.process_due()

    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    ready_file.write_text(f"http://127.0.0.1:{server.server_port}", encoding="utf-8")
    try:
        server.serve_forever()
    finally:
        stop.set()
        server.server_close()
        worker.join(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()
    serve(args.directory, args.ready_file)
