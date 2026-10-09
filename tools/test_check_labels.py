"""Tests for the image-configuration validator."""

import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "tools" / "check-labels.sh"
REQUIREMENTS = ("scratch", "full-history", "second-input", "sarif", "image-input")


class CheckLabelsTests(unittest.TestCase):
    def config(self, **overrides: object) -> dict[str, object]:
        labels: dict[str, object] = {
            f"org.nwarila.workflow.{name}": "false" for name in REQUIREMENTS
        }
        labels.update(overrides)
        return {"User": "65532:65532", "Labels": labels}

    def run_checker(self, data: object, *arguments: str) -> subprocess.CompletedProcess[str]:
        input_text = data if isinstance(data, str) else json.dumps(data)
        return subprocess.run(
            ["bash", str(CHECKER), *arguments],
            cwd=ROOT,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_shipped_requirement_sets_pass(self) -> None:
        for true_requirements in (("scratch", "second-input"), ("second-input",)):
            with self.subTest(true_requirements=true_requirements):
                overrides = {
                    f"org.nwarila.workflow.{name}": "true" for name in true_requirements
                }
                done = self.run_checker(self.config(**overrides))
                self.assertEqual((done.returncode, done.stderr), (0, ""))
                self.assertTrue(done.stdout.startswith("labels ok: "))

    def test_user_must_be_fixed_nonroot_identity(self) -> None:
        for user in (None, "0:0", 65532):
            with self.subTest(user=user):
                config = self.config()
                if user is None:
                    del config["User"]
                else:
                    config["User"] = user
                done = self.run_checker(config)
                self.assertEqual(done.returncode, 1)
                self.assertEqual(done.stderr, "image user must be 65532:65532\n")

    def test_every_requirement_is_required_and_boolean_text(self) -> None:
        for name in REQUIREMENTS:
            key = f"org.nwarila.workflow.{name}"
            for value in (None, "yes", True, False):
                with self.subTest(name=name, value=value):
                    config = self.config()
                    labels = config["Labels"]
                    assert isinstance(labels, dict)
                    if value is None:
                        del labels[key]
                    else:
                        labels[key] = value
                    done = self.run_checker(config)
                    self.assertEqual(done.returncode, 1)
                    self.assertEqual(done.stderr, f"invalid or missing label: {key}\n")

    def test_unsupported_requirements_are_refused(self) -> None:
        for name in ("full-history", "sarif", "image-input"):
            with self.subTest(name=name):
                key = f"org.nwarila.workflow.{name}"
                done = self.run_checker(self.config(**{key: "true"}))
                self.assertEqual(done.returncode, 1)
                self.assertEqual(
                    done.stderr,
                    f"label {key} is true, but contract 2 does not provide {name} yet\n",
                )

    def test_malformed_json_fails(self) -> None:
        self.assertNotEqual(self.run_checker("{").returncode, 0)

    def test_arguments_are_refused_with_usage(self) -> None:
        for arguments in (("config.json",), ("one", "two")):
            with self.subTest(arguments=arguments):
                done = self.run_checker(self.config(), *arguments)
                self.assertEqual(done.returncode, 1)
                self.assertEqual(
                    done.stderr,
                    f"usage: <image config JSON> | {CHECKER}\n",
                )


if __name__ == "__main__":
    unittest.main()
