"""Check retrieval and reject malformed provenance in isolated package copies."""

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "hc.py"
SOURCE_DIR = None


class PackageTests(unittest.TestCase):
    def setUp(self):
        # Keep scratch files inside the user's home, including on Windows.
        self.temp = tempfile.TemporaryDirectory(dir=Path.home())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / ROOT.name
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns("__pycache__"))

    def run_helper(self, *args):
        return subprocess.run(
            [sys.executable, str(HELPER), *args, "--root", str(self.root)],
            capture_output=True, text=True,
        )

    def mutate(self, change):
        path = self.root / "hc_registry.yaml"
        registry = yaml.safe_load(path.read_text(encoding="utf-8"))
        change(registry)
        path.write_text(yaml.safe_dump(registry, sort_keys=False), encoding="utf-8")

    def reject(self, message, *args):
        result = self.run_helper("check", *args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_clean_package(self):
        result = self.run_helper("check")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_relative_root(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), "check", "--root", "."],
            cwd=self.root, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_selective_retrieval_and_aliases(self):
        result = self.run_helper("show", "right_problem", "opportunity_cost", "cost_benefit")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = yaml.safe_load(result.stdout)
        self.assertEqual(set(data["operators"]), {"right_problem", "cost_benefit"})
        self.assertNotIn("constraints", data["operators"])
        self.assertEqual(data["operators"]["cost_benefit"]["official_name"], "#utility")
        self.assertIn("dlo_sunk_costs", data["source_objectives"])
        self.assertIn("dlo2017", data["sources"])

    def test_unknown_operator(self):
        result = self.run_helper("show", "absent_operator")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown operator", result.stderr)

    def test_duplicate_yaml(self):
        path = self.root / "hc_registry.yaml"
        with path.open("a", encoding="utf-8") as stream:
            stream.write("\ngroups: {}\n")
        self.reject("Duplicate YAML key")

    def test_broken_relationship(self):
        self.mutate(lambda r: r["groups"]["problem_framing"]["right_problem"].update(
            related_hcs=["absent_operator"]))
        self.reject("Broken related HC")

    def test_false_official_claim(self):
        self.mutate(lambda r: r["groups"]["problem_framing"]["right_problem"].update(
            official_name="#invented"))
        self.reject("Derived operator claims an official name")

    def test_bad_example_reference(self):
        self.mutate(lambda r: r["groups"]["problem_framing"]["right_problem"].update(
            example_refs=["revenue_cause"]))
        self.reject("Example selection omits")

    def test_bad_example_is_not_positive_reference(self):
        self.mutate(lambda r: r["groups"]["problem_framing"]["right_problem"].update(
            example_refs=["bad_name_dropping"]))
        self.reject("Positive reference targets bad example")

    def test_router_labels_match_registry(self):
        original = (self.root / "hc_registry.yaml").read_text(encoding="utf-8")
        for group, name, label in [
            ("problem_framing", "variables", "diagnostic"),
            ("problem_solving", "constraints", "negotiation"),
            ("decision_making", "cost_benefit", "negotiation"),
            ("decision_making", "cost_benefit", "ethical"),
        ]:
            with self.subTest(operator=name, label=label):
                (self.root / "hc_registry.yaml").write_text(original, encoding="utf-8")
                self.mutate(lambda r: r["groups"][group][name]["use_when"].remove(label))
                self.reject(f"Router/use_when mismatch: {label}/{name}")

    def test_unknown_router_operator(self):
        path = self.root / "SKILL.md"
        path.write_text(path.read_text(encoding="utf-8").replace(
            "| diagnostic | `right_problem`", "| diagnostic | `absent_operator`"), encoding="utf-8")
        self.reject("Unknown router operator")

    def test_unknown_conditional_cue(self):
        path = self.root / "SKILL.md"
        path.write_text(path.read_text(encoding="utf-8").replace(
            "consider `plausibility`", "consider `absent_cue`"), encoding="utf-8")
        self.reject("Unknown routing or selection cue")

    def test_missing_example_back_reference(self):
        self.mutate(lambda r: r["groups"]["problem_solving"]["constraints"]["example_refs"].remove(
            "supplier_agreement"))
        self.reject("Missing example back-reference")

    def test_missing_router_label(self):
        path = self.root / "SKILL.md"
        lines = path.read_text(encoding="utf-8").splitlines()
        path.write_text("\n".join(line for line in lines if not line.startswith("| diagnostic |")),
                        encoding="utf-8")
        self.reject("Router must cover each problem label once")

    def test_broken_supporting_objective(self):
        self.mutate(lambda r: r["groups"]["decision_making"]["cost_benefit"].update(
            supporting_objectives=["absent_objective"]))
        self.reject("Broken supporting objective")

    def test_utf8_source_decoding_under_legacy_locale(self):
        spec = importlib.util.spec_from_file_location("hc_under_test", HELPER)
        helper = importlib.util.module_from_spec(spec)
        with mock.patch.object(sys, "dont_write_bytecode", True):
            spec.loader.exec_module(helper)
        content = b"test PDF"
        (self.root / "intro.pdf").write_bytes(content)
        registry = {"sources": {"intro2017": {"sha256": hashlib.sha256(content).hexdigest()}},
                    "source_objectives": {}}
        # A closing quotation mark contains a byte that cp1252 cannot decode.
        output = "A bullet \u2022 and a quote \u201d\f".encode("utf-8")

        def legacy_locale_output(command, **kwargs):
            self.assertIn("-enc", command)
            self.assertEqual(command[command.index("-enc") + 1], "UTF-8")
            return output.decode(kwargs.get("encoding", "cp1252"))

        with mock.patch.object(helper.subprocess, "check_output", side_effect=legacy_locale_output):
            with contextlib.redirect_stdout(io.StringIO()):
                helper.verify_sources(self.root, registry, {})

    def test_broken_derivation(self):
        self.mutate(lambda r: r["groups"]["problem_framing"]["right_problem"].update(
            derived_from=["absent_objective"]))
        self.reject("Broken derivation")

    def test_recorded_evaluation_totals_and_errata(self):
        data = json.loads((ROOT / "evals" / "online-check.json").read_text(encoding="utf-8"))
        self.assertEqual(len({c["id"] for c in data["cases"]}), len(data["cases"]))
        self.assertEqual(sum(c["points"] for c in data["cases"]), data["total_points"])
        self.assertEqual(sum(c["max_points"] for c in data["cases"]), data["max_points"])
        exclusions = {(c["case"], c["criterion_index"])
                      for c in data["assessable_result"]["excluded_criteria"]}
        points = maximum = threshold_passes = complete_cases = 0
        for case in data["cases"]:
            assessable_scores = []
            for index, score in enumerate(case["criterion_scores"], 1):
                if (case["id"], index) not in exclusions:
                    assessable_scores.append(score)
                    points += score
                    maximum += 2
            threshold_passes += sum(assessable_scores) >= 0.8 * 2 * len(assessable_scores)
            complete_cases += all(score == 2 for score in assessable_scores)
        self.assertEqual((points, maximum),
                         (data["assessable_result"]["points"], data["assessable_result"]["max_points"]))
        self.assertEqual(threshold_passes, data["assessable_result"]["cases_passing_threshold"])
        self.assertEqual(complete_cases, data["assessable_result"]["cases_with_all_assessable_criteria_at_2"])
        self.assertTrue(any(e.get("case") == "marginal_inference" for e in data["errata"]))

    def test_new_scenario_record_consistency(self):
        data = json.loads((ROOT / "evals" / "new-scenarios.json").read_text(encoding="utf-8"))
        cases = {case["id"]: case for case in data["cases"]}
        self.assertEqual(len(cases), len(data["cases"]))
        grades = data["independent_grading"]["cases"]
        self.assertEqual(set(cases), {grade["id"] for grade in grades})
        total = maximum = 0
        for grade in grades:
            case = cases[grade["id"]]
            self.assertEqual(case["criteria"], [c["criterion"] for c in grade["criteria"]])
            self.assertEqual(sum(c["score"] for c in grade["criteria"]), grade["score"])
            self.assertEqual(len(grade["criteria"]) * 2, grade["maximum_score"])
            self.assertEqual(case["solver_output"]["selected_operators"],
                             grade["operator_audit"]["selected_operators"])
            total += grade["score"]
            maximum += grade["maximum_score"]
        summary = data["independent_grading"]["summary"]
        self.assertEqual((total, maximum), (summary["total_score"], summary["maximum_score"]))

    def test_wrong_source_type(self):
        if SOURCE_DIR is None:
            self.skipTest("Pass --source-dir to verify against primary PDFs")
        self.mutate(lambda r: r["groups"]["problem_solving"]["constraints"].update(type="habit"))
        self.reject("Wrong official H/C type", "--source-dir", str(SOURCE_DIR))

    def test_changed_source_digest(self):
        if SOURCE_DIR is None:
            self.skipTest("Pass --source-dir to verify against primary PDFs")
        self.mutate(lambda r: r["sources"]["intro2017"].update(sha256="0" * 64))
        self.reject("Source changed", "--source-dir", str(SOURCE_DIR))

    def test_wrong_official_page(self):
        if SOURCE_DIR is None:
            self.skipTest("Pass --source-dir to verify against primary PDFs")
        self.mutate(lambda r: r["groups"]["problem_solving"]["constraints"]["source"].update(
            location="p. 999"))
        self.reject("Source page outside document", "--source-dir", str(SOURCE_DIR))

    def test_wrong_objective_page(self):
        if SOURCE_DIR is None:
            self.skipTest("Pass --source-dir to verify against primary PDFs")
        self.mutate(lambda r: r["source_objectives"]["dlo_framing"].update(
            location="p. 999, Analyzing Problems, bullets 1-2"))
        self.reject("Source page outside document", "--source-dir", str(SOURCE_DIR))

    def test_wrong_objective_bullet(self):
        if SOURCE_DIR is None:
            self.skipTest("Pass --source-dir to verify against primary PDFs")
        self.mutate(lambda r: r["source_objectives"]["dlo_framing"].update(
            location="p. 5, Analyzing Problems, bullets 999"))
        self.reject("Objective bullet range outside section", "--source-dir", str(SOURCE_DIR))

    def test_wrong_objective_section(self):
        if SOURCE_DIR is None:
            self.skipTest("Pass --source-dir to verify against primary PDFs")
        self.mutate(lambda r: r["source_objectives"]["dlo_framing"].update(
            location="p. 5, Missing Section, bullets 1-2"))
        self.reject("Section absent on stated page", "--source-dir", str(SOURCE_DIR))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source-dir", type=Path)
    options, remaining = parser.parse_known_args()
    SOURCE_DIR = options.source_dir
    unittest.main(argv=[sys.argv[0], *remaining])
