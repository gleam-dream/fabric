#!/usr/bin/env python3
"""Explicit bounded provider comparison and separate-VM writing demonstration."""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parent.parent
CORPUS = PACKAGE / "fixtures" / "cases.json"
LABELS = ("approve", "revise", "reject")


@dataclass(frozen=True)
class Case:
    identity: str
    expected: str
    draft: dict[str, object]


def object_fields(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(k, str) for k in value):
        raise ValueError("expected a JSON object")
    return value


def cases(path: Path) -> list[Case]:
    raw: object = json.loads(path.read_text())
    if not isinstance(raw, list) or len(raw) != 12:
        raise ValueError("the frozen corpus must contain 12 cases")
    parsed = []
    for row in raw:
        record = object_fields(row)
        identity, expected = record.get("id"), record.get("expected")
        if not isinstance(identity, str) or not identity or expected not in LABELS:
            raise ValueError("invalid case identity or expected label")
        draft = object_fields(record.get("draft"))
        text = object_fields(draft.get("text"))
        if set(text) != {"source", "brief", "body"} or not all(
            isinstance(v, str) for v in text.values()
        ):
            raise ValueError("invalid case text")
        if type(draft.get("generation")) is not int or draft["generation"] != 1:
            raise ValueError("evaluation drafts must have generation 1")
        parsed.append(Case(identity, str(expected), draft))
    if len({case.identity for case in parsed}) != len(parsed):
        raise ValueError("duplicate case identity")
    if any(sum(case.expected == label for case in parsed) != 4 for label in LABELS):
        raise ValueError("the corpus must have four cases per label")
    return parsed


def environment(dotenv: Path) -> dict[str, str]:
    env = dict(os.environ)
    allowed = {
        "OPENAI_API_KEY",
        "TYPESAFE_API_KEY",
        "FABRIC_DECISION_MODEL",
        "FABRIC_CLASSIFIER_MODEL",
    }
    if dotenv.exists():
        for line in dotenv.read_text().splitlines():
            name, separator, value = line.strip().removeprefix("export ").partition("=")
            name = name.strip()
            if separator and name in allowed and not env.get(name):
                value = value.strip()
                if len(value) > 1 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                env[name] = value
    for name in ("OPENAI_API_KEY", "TYPESAFE_API_KEY"):
        if not env.get(name):
            raise ValueError(f"{name} is missing; no live requests sent")
    return env


def invoke(env: dict[str, str], capture: Path) -> dict[str, object]:
    try:
        result = subprocess.run(
            ["gleam", "run", "-m", "fabric_writing/cli"],
            cwd=PACKAGE,
            env=env,
            capture_output=True,
            text=True,
            timeout=150,
        )
    except subprocess.TimeoutExpired:
        capture.write_text("Provider command exceeded the 150-second process bound.\n")
        raise RuntimeError(f"provider command timed out; see {capture}") from None
    output = result.stdout + result.stderr
    for name in ("OPENAI_API_KEY", "TYPESAFE_API_KEY"):
        output = output.replace(env[name], "[REDACTED]")
    capture.write_text(output)
    if result.returncode:
        raise RuntimeError(f"provider command failed; see {capture}")
    rows = [line for line in output.splitlines() if line.startswith("{")]
    if len(rows) != 1:
        raise RuntimeError(f"expected one result; see {capture}")
    return object_fields(json.loads(rows[0]))


def measurement(value: dict[str, object]) -> dict[str, object]:
    elapsed = value.get("elapsed_ms")
    if type(elapsed) is not int or elapsed < 0:
        raise ValueError("missing or invalid measured latency")
    if value.get("status") == "failed":
        return value
    if value.get("status") != "completed" or value.get("decision") not in LABELS:
        raise ValueError("missing or invalid decision")
    if value.get("usage") is not None:
        usage = object_fields(value["usage"])
        if any(
            type(usage.get(k)) is not int or usage[k] < 0
            for k in ("input_tokens", "output_tokens")
        ):
            raise ValueError("missing or invalid reported token usage")
    return value


def summarize(samples: list[dict[str, object]]) -> dict[str, object]:
    summary = {}
    for reviewer in ("llm", "typesafe"):
        group = [s for s in samples if s["reviewer"] == reviewer]
        valid = [
            s
            for s in group
            if s.get("status") == "completed" and s.get("decision") in LABELS
        ]
        times = [s["elapsed_ms"] for s in group if type(s.get("elapsed_ms")) is int]
        usage = [object_fields(s["usage"]) for s in valid if s.get("usage") is not None]
        summary[reviewer] = {
            "cases": len(group),
            "valid": len(valid),
            "failed_or_invalid": len(group) - len(valid),
            "correct": sum(s["decision"] == s["expected"] for s in valid),
            "confusion": {
                label: {
                    chosen: sum(
                        s["expected"] == label and s.get("decision") == chosen
                        for s in valid
                    )
                    for chosen in LABELS
                }
                for label in LABELS
            },
            "median_elapsed_ms": statistics.median(times) if times else None,
            "min_elapsed_ms": min(times) if times else None,
            "max_elapsed_ms": max(times) if times else None,
            "usage_samples": len(usage),
            "input_tokens": sum(u["input_tokens"] for u in usage),
            "output_tokens": sum(u["output_tokens"] for u in usage),
            "billing_cost": None,
        }
    return summary


def compare(env: dict[str, str], output: Path) -> None:
    samples = []
    for index, case in enumerate(cases(CORPUS)):
        # Expected labels/rationales never reach either producer.
        request = output / f"{case.identity}.input.json"
        request.write_text(json.dumps(case.draft) + "\n")
        order = ("llm", "typesafe") if index % 2 == 0 else ("typesafe", "llm")
        for reviewer in order:
            print(f"Reviewing {case.identity}: {reviewer}", flush=True)
            config = dict(
                env,
                FABRIC_WRITING_MODE="review",
                FABRIC_WRITING_REVIEWER=reviewer,
                FABRIC_WRITING_INPUT=str(request),
            )
            capture = output / f"{case.identity}.{reviewer}.log"
            try:
                sample = measurement(invoke(config, capture))
            except (RuntimeError, ValueError) as error:
                # Count the failed attempt without selectively retrying it or
                # fabricating latency/usage. Remaining planned cases still run.
                sample = {"status": "failed", "problem": str(error)}
            sample.update(case=case.identity, expected=case.expected, reviewer=reviewer)
            samples.append(sample)
            (output / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
            (output / "summary.json").write_text(
                json.dumps(summarize(samples), indent=2) + "\n"
            )


def workflow(env: dict[str, str], output: Path) -> None:
    for reviewer in ("llm", "typesafe"):
        print(f"Running live writing workflow: {reviewer}", flush=True)
        config = dict(
            env,
            FABRIC_WRITING_REVIEWER=reviewer,
            FABRIC_WRITING_DIRECTORY=str(output / f"workflow-{reviewer}"),
            FABRIC_WRITING_ID="article",
            FABRIC_WRITING_SOURCE=str(PACKAGE / "fixtures" / "source.txt"),
            FABRIC_WRITING_BRIEF="State the opening date, price and address in one sentence.",
        )
        before = invoke(
            dict(config, FABRIC_WRITING_MODE="start"),
            output / f"workflow-{reviewer}.start.log",
        )
        if before.get("status") != "awaiting_approval":
            raise RuntimeError(
                f"{reviewer} workflow did not reach approval; evidence retained"
            )
        after = invoke(
            dict(config, FABRIC_WRITING_MODE="inspect"),
            output / f"workflow-{reviewer}.restart.log",
        )
        if before != after:
            raise RuntimeError(
                "VM restart changed the draft, receipts or approval revision"
            )
        # Explicit demonstration action through Fabric's approval API. This is
        # a scripted operator in a local example, not a claim of human review.
        approved = invoke(
            dict(
                config,
                FABRIC_WRITING_MODE="approve",
                FABRIC_WRITING_EXPECTED_REVISION=str(after["revision"]),
            ),
            output / f"workflow-{reviewer}.approve.log",
        )
        if approved.get("status") != "published":
            raise RuntimeError(f"{reviewer} workflow did not save an artifact")
        receipts = after["receipts"]
        completed = approved["receipts"]
        if (
            not isinstance(receipts, list)
            or not isinstance(completed, list)
            or completed[:-1] != receipts
        ):
            raise RuntimeError(
                "approval changed previously completed provider receipts"
            )
        artifact = object_fields(approved["artifact"])
        path = artifact.get("path")
        if not isinstance(path, str):
            raise RuntimeError("missing artifact path")
        digest = hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()
        if digest != artifact.get("sha256"):
            raise RuntimeError("artifact content differs from its durable receipt")
        (output / f"workflow-{reviewer}.json").write_text(
            json.dumps(
                {
                    "before": before,
                    "after_restart": after,
                    "published": approved,
                    "approval_actor": "scripted demonstration operator",
                },
                indent=2,
            )
            + "\n"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--live",
        action="store_true",
        help="authorize up to 24 comparison requests plus at most six generation/review requests per workflow",
    )
    parser.add_argument("--mode", choices=("compare", "workflow", "all"), default="all")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.live:
        parser.error("--live is required; provider calls can incur charges")
    output = args.output.resolve()
    env = environment(ROOT / ".env.local")
    cases(CORPUS)
    output.mkdir(parents=True, exist_ok=False)
    (output / "run.json").write_text(
        json.dumps(
            {
                "started_at": datetime.now(timezone.utc).isoformat(),
                "corpus_sha256": hashlib.sha256(CORPUS.read_bytes()).hexdigest(),
                "mode": args.mode,
                "case_count": 12,
                "generation_max_output_tokens": 300,
                "review_max_output_tokens": 64,
                "provider_deadline_ms": 20_000,
                "order": "alternating reviewer order per case",
                "implicit_retries": False,
            },
            indent=2,
        )
        + "\n"
    )
    if args.mode in ("compare", "all"):
        compare(env, output)
    if args.mode in ("workflow", "all"):
        workflow(env, output)
    print(f"Live evidence saved to {output}")


if __name__ == "__main__":
    main()
