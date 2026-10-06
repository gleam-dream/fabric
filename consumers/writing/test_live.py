"""Offline checks for the live evidence boundary; never call a provider."""

import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_live


class EvidenceTest(unittest.TestCase):
    def test_corpus_is_balanced_and_expected_labels_are_not_provider_input(
        self,
    ) -> None:
        cases = run_live.cases(run_live.CORPUS)
        self.assertEqual(len(cases), 12)
        for case in cases:
            self.assertEqual(set(case.draft), {"text", "generation"})
            self.assertEqual(set(case.draft["text"]), {"source", "brief", "body"})
        self.assertEqual(
            {
                label: sum(c.expected == label for c in cases)
                for label in run_live.LABELS
            },
            {"approve": 4, "revise": 4, "reject": 4},
        )

    def test_bad_corpus_is_rejected_before_live_requests(self) -> None:
        original = json.loads(run_live.CORPUS.read_text())
        for change in ("duplicate", "label", "generation", "text"):
            rows = copy.deepcopy(original)
            if change == "duplicate":
                rows[1]["id"] = rows[0]["id"]
            elif change == "label":
                rows[0]["expected"] = "unknown"
            elif change == "generation":
                rows[0]["draft"]["generation"] = True
            else:
                rows[0]["draft"]["text"]["source"] = None
            with self.subTest(change=change), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "cases.json"
                path.write_text(json.dumps(rows))
                with self.assertRaises(ValueError):
                    run_live.cases(path)

    def test_dotenv_is_data_with_allowlisted_keys_and_environment_precedence(
        self,
    ) -> None:
        with (
            tempfile.TemporaryDirectory() as folder,
            patch.dict(os.environ, {"OPENAI_API_KEY": "existing"}, clear=True),
        ):
            dotenv = Path(folder) / ".env.local"
            dotenv.write_text(
                "OPENAI_API_KEY=\"replaced\"\nexport TYPESAFE_API_KEY='literal$(command)'\nUNRELATED_SECRET=ignored\n"
            )
            env = run_live.environment(dotenv)
            self.assertEqual(env["OPENAI_API_KEY"], "existing")
            self.assertEqual(env["TYPESAFE_API_KEY"], "literal$(command)")
            self.assertNotIn("UNRELATED_SECRET", env)
        with (
            tempfile.TemporaryDirectory() as folder,
            patch.dict(os.environ, {}, clear=True),
        ):
            with self.assertRaisesRegex(ValueError, "OPENAI_API_KEY is missing"):
                run_live.environment(Path(folder) / "absent")

    def test_invalid_metrics_are_not_accepted_as_measurements(self) -> None:
        valid = {
            "status": "completed",
            "decision": "approve",
            "elapsed_ms": 25,
            "usage": None,
        }
        self.assertEqual(run_live.measurement(valid), valid)
        for changes in (
            {"elapsed_ms": True},
            {"elapsed_ms": -1},
            {"decision": "unknown"},
            {"usage": {"input_tokens": 4, "output_tokens": -1}},
            {"usage": {}},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                run_live.measurement(dict(valid, **changes))

    def test_empty_environment_key_uses_dotenv(self) -> None:
        with (
            tempfile.TemporaryDirectory() as folder,
            patch.dict(os.environ, {"OPENAI_API_KEY": ""}, clear=True),
        ):
            dotenv = Path(folder) / ".env.local"
            dotenv.write_text(
                'OPENAI_API_KEY = "from-file"\nTYPESAFE_API_KEY=from-file-too\n'
            )
            env = run_live.environment(dotenv)
            self.assertEqual(env["OPENAI_API_KEY"], "from-file")
            self.assertEqual(env["TYPESAFE_API_KEY"], "from-file-too")

    def test_failed_and_wrong_decisions_stay_in_denominator(self) -> None:
        samples = [
            {
                "reviewer": "llm",
                "status": "completed",
                "expected": "approve",
                "decision": "approve",
                "elapsed_ms": 10,
                "usage": {"input_tokens": 8, "output_tokens": 2},
            },
            {
                "reviewer": "llm",
                "status": "completed",
                "expected": "revise",
                "decision": "reject",
                "elapsed_ms": 30,
                "usage": None,
            },
            {
                "reviewer": "llm",
                "status": "failed",
                "expected": "reject",
                "elapsed_ms": 50,
            },
        ]
        llm = run_live.summarize(samples)["llm"]
        self.assertEqual(
            (llm["cases"], llm["valid"], llm["correct"], llm["failed_or_invalid"]),
            (3, 2, 1, 1),
        )
        self.assertEqual(llm["median_elapsed_ms"], 30)
        self.assertEqual(llm["usage_samples"], 1)
        self.assertEqual(llm["input_tokens"], 8)
        self.assertEqual(llm["confusion"]["revise"]["reject"], 1)
        self.assertIsNone(llm["billing_cost"])

    def test_comparison_attempts_each_case_once_and_retains_command_failures(
        self,
    ) -> None:
        calls = []

        def invoke(env: dict[str, str], capture: Path) -> dict[str, object]:
            calls.append(
                (Path(env["FABRIC_WRITING_INPUT"]).name, env["FABRIC_WRITING_REVIEWER"])
            )
            request = json.loads(Path(env["FABRIC_WRITING_INPUT"]).read_text())
            self.assertNotIn("expected", request)
            if len(calls) == 1:
                raise RuntimeError("scripted process failure")
            return {
                "status": "completed",
                "decision": "approve",
                "elapsed_ms": 1,
                "usage": None,
            }

        with (
            tempfile.TemporaryDirectory() as folder,
            patch.object(run_live, "invoke", invoke),
            patch("builtins.print"),
        ):
            output = Path(folder)
            run_live.compare({}, output)
            samples = json.loads((output / "samples.json").read_text())
            self.assertEqual(len(calls), 24)
            self.assertEqual(len(set(calls)), 24)
            self.assertEqual(samples[0]["status"], "failed")
            self.assertEqual(
                [reviewer for _, reviewer in calls[:4]],
                ["llm", "typesafe", "typesafe", "llm"],
            )
            self.assertEqual(
                json.loads((output / "summary.json").read_text())["llm"][
                    "failed_or_invalid"
                ],
                1,
            )


if __name__ == "__main__":
    unittest.main()
