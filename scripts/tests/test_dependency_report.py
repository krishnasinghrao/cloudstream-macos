"""Licence and advisory reporting over a CycloneDX inventory, without the network."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "dependency_report.py"
spec = importlib.util.spec_from_file_location("dependency_report", SCRIPT)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def component(group, name, version):
    return {"group": group, "name": name, "version": version, "purl": f"pkg:maven/{group}/{name}@{version}"}


def pom(cache: Path, group, name, version, licenses=(), parent=None):
    directory = cache / group / name / version / "hash"
    directory.mkdir(parents=True)
    body = "".join(f"<license><name>{entry}</name></license>" for entry in licenses)
    parent_xml = ("<parent><groupId>{}</groupId><artifactId>{}</artifactId><version>{}</version></parent>".format(*parent)
                  if parent else "")
    (directory / f"{name}-{version}.pom").write_text(
        f'<project xmlns="http://maven.apache.org/POM/4.0.0">{parent_xml}<licenses>{body}</licenses></project>'
        if licenses else f'<project xmlns="http://maven.apache.org/POM/4.0.0">{parent_xml}</project>')


class DependencyReportTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.root = Path(self.work.name)
        self.cache = self.root / "cache"
        self.sbom = self.root / "sbom.json"

    def tearDown(self):
        self.work.cleanup()

    def inventory(self, *entries):
        self.sbom.write_text(json.dumps({"components": list(entries)}))

    def test_licences_come_from_the_module_or_its_parent_and_unknown_is_never_guessed(self):
        self.inventory(component("a", "apache", "1"), component("b", "child", "2"), component("c", "dual", "3"),
                       component("d", "gpl2", "4"), component("e", "nothing", "5"), component("f", "missing", "6"),
                       component("com.github.Blatzar", "NiceHttp", "0.4.18"))
        pom(self.cache, "a", "apache", "1", ["The Apache License, Version 2.0"])
        pom(self.cache, "b", "child", "2", parent=("b", "parent", "2"))
        pom(self.cache, "b", "parent", "2", ["MIT License"])
        pom(self.cache, "c", "dual", "3", ["Mozilla Public License 1.1", "GPL-3.0"])
        pom(self.cache, "d", "gpl2", "4", ["GPL 2"])
        pom(self.cache, "e", "nothing", "5")
        pom(self.cache, "com.github.Blatzar", "NiceHttp", "0.4.18", ["GNU General Public License v3.0"])
        rows, review = report.licenses(self.sbom, self.cache)
        status = {row["purl"].split("/")[-1].split("@")[0]: row["status"] for row in rows}
        self.assertEqual(status, {"apache": "permissive", "child": "permissive", "dual": "weak-copyleft", "gpl2": "review",
                                  "nothing": "unknown", "missing": "unknown", "NiceHttp": "reviewed"})
        self.assertEqual(len(review), 3)
        self.assertTrue(any("gpl2" in line and "GPL 2" in line for line in review))

    def test_advisories_apply_recorded_decisions_per_package_and_flag_the_rest(self):
        self.inventory(component("g", "clean", "1"), component("g", "known", "2"), component("g", "new", "3"))
        answer = self.root / "osv.json"
        answer.write_text(json.dumps({"results": [{}, {"vulns": [{"id": "GHSA-known"}, {"id": "GHSA-fresh"}]},
                                                  {"vulns": [{"id": "GHSA-known"}]}]}))
        triage = {"g:known": {"GHSA-known": {"decision": "not-applicable", "reason": "unused feature"}}}
        findings, complete = report.advisories(self.sbom, answer, triage)
        self.assertTrue(complete)
        self.assertEqual(findings, [
            {"purl": "pkg:maven/g/known@2", "untriaged": ["GHSA-fresh"],
             "triaged": {"GHSA-known": {"decision": "not-applicable", "reason": "unused feature"}}},
            # The same id on another package has no decision of its own.
            {"purl": "pkg:maven/g/new@3", "untriaged": ["GHSA-known"], "triaged": {}},
        ])

    def test_a_failed_or_partial_lookup_is_not_a_clean_result(self):
        self.inventory(component("g", "one", "1"), component("g", "two", "2"))
        partial = self.root / "partial.json"
        partial.write_text(json.dumps({"results": [{}]}))
        self.assertEqual(report.advisories(self.sbom, partial), ([], False))
        with patch.object(report.urllib.request, "urlopen", side_effect=OSError("offline")):
            self.assertEqual(report.advisories(self.sbom, None), ([], False))
        with patch("sys.argv", ["dependency_report.py", "advisories", str(self.sbom), "--offline", str(partial)]):
            self.assertEqual(report.main(), 2)

    def test_the_recorded_triage_names_only_packages_and_decisions_the_report_understands(self):
        triage = json.loads((SCRIPT.parents[1] / "engine/advisory-triage.json").read_text())
        for package, decisions in triage["packages"].items():
            self.assertRegex(package, r"^[\w.\-]+:[\w.\-]+$")
            for identifier, decision in decisions.items():
                self.assertRegex(identifier, r"^(GHSA|CVE)-")
                self.assertIn(decision["decision"], {"not-applicable", "open", "mitigated-by-isolation"})
                self.assertTrue(decision["reason"].strip())


if __name__ == "__main__":
    unittest.main()
