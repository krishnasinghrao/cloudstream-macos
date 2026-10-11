#!/usr/bin/env python3
"""Licence and advisory report for what daemon.jar actually packs (plan B02).

    dependency_report.py licenses   <sbom.cdx.json> [--gradle-cache DIR] [--output FILE]
    dependency_report.py advisories <sbom.cdx.json> [--triage FILE] [--output FILE] [--offline FILE]

Both read the CycloneDX inventory written by `./gradlew :engine:sbom`,
so they describe the resolved, locked versions and nothing else.

`licenses` reads each component's own POM (and its parent POMs) from the
Gradle module cache. A component whose licence cannot be established is
reported as unknown, never guessed. Exit status 1 when a licence needs review
(unknown, or a copyleft family that is not on the reviewed list).

`advisories` asks OSV (https://osv.dev) about every Maven coordinate. Only
public package names and versions are sent. `--triage FILE` names the
recorded decisions (engine/advisory-triage.json): an advisory listed there
for that package is reported with its decision instead of failing. Exit
status 1 when an advisory without a recorded decision applies to a packed
version, 2 when the service could not be reached; a failed lookup is never
reported as "no advisories". `--offline FILE` reads a saved OSV response
instead (tests).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ElementTree
from pathlib import Path

OSV_BATCH = "https://api.osv.dev/v1/querybatch"

# Licence families as they appear in POMs, most specific first.
FAMILIES = [
    ("AGPL", re.compile(r"affero|agpl", re.I)),
    ("LGPL", re.compile(r"lesser|library general|lgpl", re.I)),
    ("GPL", re.compile(r"general public|\bgpl", re.I)),
    ("MPL", re.compile(r"mozilla|\bmpl", re.I)),
    ("EPL", re.compile(r"eclipse|\bepl", re.I)),
    ("Apache-2.0", re.compile(r"apache", re.I)),
    ("MIT", re.compile(r"\bmit\b", re.I)),
    ("BSD", re.compile(r"\bbsd|edl|eclipse distribution", re.I)),
    ("ISC", re.compile(r"\bisc\b", re.I)),
    ("Public-Domain", re.compile(r"public domain|cc0|unlicense", re.I)),
]
PERMISSIVE = {"Apache-2.0", "MIT", "BSD", "ISC", "Public-Domain"}
# Components whose non-permissive licence was reviewed for this product, with
# the reason. Anything else outside PERMISSIVE needs a person to look at it.
REVIEWED = {
    # The provider engine this product is built from; the product is GPL-3.0.
    "pkg:generic/cloudstream/library-jvm": "in-repository engine, same licence as the product",
    "pkg:maven/com.github.teamnewpipe/NewPipeExtractor": "GPL-3.0, compatible with the product's GPL-3.0 licence",
    "pkg:maven/com.github.TeamNewPipe/NewPipeExtractor": "GPL-3.0, compatible with the product's GPL-3.0 licence",
    "pkg:maven/com.github.TeamNewPipe.NewPipeExtractor/extractor": "GPL-3.0, compatible with the product's GPL-3.0 licence",
    "pkg:maven/com.github.TeamNewPipe.NewPipeExtractor/timeago-parser": "GPL-3.0, compatible with the product's GPL-3.0 licence",
    "pkg:maven/com.github.Blatzar/NiceHttp": "GPL-3.0, compatible with the product's GPL-3.0 licence",
}
WEAK_COPYLEFT = {"MPL", "EPL", "LGPL"}


def components(sbom: Path) -> list[dict]:
    document = json.loads(sbom.read_text())
    return sorted(document.get("components", []), key=lambda entry: entry["purl"])


def strip(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def pom_path(cache: Path, group: str, name: str, version: str) -> Path | None:
    directory = cache / group / name / version
    found = sorted(directory.glob(f"*/{name}-{version}.pom")) if directory.is_dir() else []
    return found[0] if found else None


def pom_licenses(cache: Path, group: str, name: str, version: str, depth: int = 0) -> list[str] | None:
    """Licence names declared for a module, following parent POMs. None: no POM in the cache."""
    path = pom_path(cache, group, name, version)
    if path is None:
        return None
    try:
        root = ElementTree.parse(path).getroot()
    except ElementTree.ParseError:
        return None
    names, parent = [], None
    for child in root:
        if strip(child.tag) == "licenses":
            for licence in child:
                for field in licence:
                    if strip(field.tag) == "name" and (field.text or "").strip():
                        names.append(field.text.strip())
        elif strip(child.tag) == "parent":
            parent = {strip(field.tag): (field.text or "").strip() for field in child}
    if names or parent is None or depth >= 6:
        return names
    inherited = pom_licenses(cache, parent.get("groupId", ""), parent.get("artifactId", ""), parent.get("version", ""), depth + 1)
    return inherited if inherited is not None else names


def family(name: str) -> str | None:
    for label, pattern in FAMILIES:
        if pattern.search(name):
            return label
    return None


def unversioned(purl: str) -> str:
    return purl.split("@", 1)[0]


def licenses(sbom: Path, cache: Path) -> tuple[list[dict], list[str]]:
    rows, review = [], []
    for entry in components(sbom):
        declared = pom_licenses(cache, entry.get("group", ""), entry["name"], entry["version"]) \
            if entry["purl"].startswith("pkg:maven/") else None
        families = sorted({family(name) or "other" for name in declared or []})
        note = REVIEWED.get(unversioned(entry["purl"]))
        if note:
            status = "reviewed"
        elif not declared:
            status = "unknown"
        elif any(item in PERMISSIVE for item in families):
            # A multi-licensed module may be used under its permissive option.
            status = "permissive"
        elif any(item in WEAK_COPYLEFT for item in families):
            # Likewise under its weak-copyleft option (unmodified library use).
            status = "weak-copyleft"
        else:
            status = "review"
        if status in ("unknown", "review"):
            review.append(f"{entry['purl']}: {', '.join(declared) if declared else 'no licence found'}")
        rows.append({"purl": entry["purl"], "declared": declared or [], "families": families, "status": status,
                     **({"note": note} if note else {})})
    return rows, review


def advisories(sbom: Path, offline: Path | None, triage: dict | None = None) -> tuple[list[dict], bool]:
    """(findings, complete). `complete` is False when the lookup did not answer for every component.

    Each finding lists `untriaged` advisory ids and `triaged` ones with their recorded decision."""
    queried = [entry for entry in components(sbom) if entry["purl"].startswith("pkg:maven/")]
    payload = {"queries": [{"package": {"ecosystem": "Maven", "name": f"{entry['group']}:{entry['name']}"},
                            "version": entry["version"]} for entry in queried]}
    if offline is not None:
        answer = json.loads(offline.read_text())
    else:
        request = urllib.request.Request(OSV_BATCH, data=json.dumps(payload).encode(),
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                answer = json.loads(response.read())
        except (OSError, ValueError, urllib.error.URLError):
            return [], False
    results = answer.get("results")
    if not isinstance(results, list) or len(results) != len(queried):
        return [], False
    findings = []
    for entry, result in zip(queried, results):
        identifiers = sorted(item["id"] for item in (result or {}).get("vulns", []) if "id" in item)
        if not identifiers:
            continue
        decisions = (triage or {}).get(f"{entry['group']}:{entry['name']}", {})
        findings.append({"purl": entry["purl"],
                         "untriaged": [identifier for identifier in identifiers if identifier not in decisions],
                         "triaged": {identifier: decisions[identifier] for identifier in identifiers if identifier in decisions}})
    return findings, True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["licenses", "advisories"])
    parser.add_argument("sbom", type=Path)
    parser.add_argument("--gradle-cache", type=Path, default=Path.home() / ".gradle/caches/modules-2/files-2.1")
    parser.add_argument("--offline", type=Path)
    parser.add_argument("--triage", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    if arguments.action == "licenses":
        rows, review = licenses(arguments.sbom, arguments.gradle_cache)
        report = {"components": rows, "needsReview": review}
        counts: dict[str, int] = {}
        for row in rows:
            counts[row["status"]] = counts.get(row["status"], 0) + 1
        print("licences: " + ", ".join(f"{count} {status}" for status, count in sorted(counts.items())))
        for line in review:
            print(f"  review: {line}", file=sys.stderr)
        status = 1 if review else 0
    else:
        triage = json.loads(arguments.triage.read_text())["packages"] if arguments.triage else None
        findings, complete = advisories(arguments.sbom, arguments.offline, triage)
        report = {"complete": complete, "findings": findings}
        if not complete:
            print("advisories: the lookup did not complete; nothing can be concluded", file=sys.stderr)
            status = 2
        else:
            untriaged = sum(len(finding["untriaged"]) for finding in findings)
            decided: dict[str, int] = {}
            for finding in findings:
                for decision in finding["triaged"].values():
                    decided[decision["decision"]] = decided.get(decision["decision"], 0) + 1
            print(f"advisories: {untriaged} without a recorded decision"
                  + "".join(f", {count} {decision}" for decision, count in sorted(decided.items())))
            for finding in findings:
                if finding["untriaged"]:
                    print(f"  {finding['purl']}: {', '.join(finding['untriaged'])}", file=sys.stderr)
            status = 1 if untriaged else 0
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
