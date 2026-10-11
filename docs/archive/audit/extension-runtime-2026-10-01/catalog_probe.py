#!/usr/bin/env python3
"""Read public catalogs without installing or executing extensions."""
import base64
import concurrent.futures
import datetime
import hashlib
import json
import pathlib
import re
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[4]
OUTPUT = pathlib.Path(__file__).with_name("catalog-results.json")


def fetch(url, limit=8 * 1024 * 1024):
    request = urllib.request.Request(url, headers={"User-Agent": "CloudStream-macOS/1", "Accept-Encoding": "identity"})
    if url.startswith("https://codeberg.org/api/v1/repos/"):
        request.add_header("Cookie", "x-robot-challenge-berlin=passed")
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read(limit + 1)
        if len(body) > limit:
            raise ValueError("response exceeds limit")
        return body, response.url


def fetch_logical(url):
    parsed = urllib.parse.urlsplit(url)
    parts = parsed.path.strip("/").split("/")
    if parsed.hostname == "codeberg.org" and len(parts) >= 6 and parts[2] in ("raw", "src"):
        api = "https://codeberg.org/api/v1/repos/" + "/".join(parts[:2]) + "/contents/" + "/".join(parts[5:]) + "?ref=" + parts[4]
        try:
            body, _ = fetch(api)
            wrapper = json.loads(body)
            if wrapper.get("encoding") != "base64":
                raise ValueError("API did not return base64")
            return base64.b64decode(wrapper["content"]), url, "codeberg-contents-api"
        except Exception:
            pass
    body, effective = fetch(url)
    return body, effective, "direct"


def probe(entry):
    name, url = entry
    result = {"name": name, "url": url}
    try:
        body, effective, transport = fetch_logical(url)
        manifest = json.loads(body)
        result.update(manifest_sha256=hashlib.sha256(body).hexdigest(), effective_url=effective, transport=transport,
                      signed="signature" in manifest, plugin_lists=manifest.get("pluginLists", []))
        plugins = []
        errors = []
        for reference in manifest.get("pluginLists", []):
            try:
                list_body, _, _ = fetch_logical(urllib.parse.urljoin(effective, reference))
                plugins.extend(json.loads(list_body))
            except Exception as error:
                errors.append({"list": reference, "error": str(error)[:300]})
        active = [p for p in plugins if p.get("status") in (1, 2)]
        valid = lambda p: bool(re.fullmatch(r"(?:sha256-)?[0-9a-fA-F]{64}", p.get("fileHash") or ""))
        result.update(total=len(plugins), active=len(active), active_with_sha256=sum(valid(p) for p in active),
                      missing_hash=sum(not p.get("fileHash") for p in active),
                      other_hash_formats=sorted(set(p.get("fileHash", "")[:12] for p in active if p.get("fileHash") and not valid(p))),
                      beta_only=sum(p.get("status") == 3 for p in plugins), list_errors=errors,
                      examples_without_sha256=[p.get("internalName", p.get("name")) for p in active if not valid(p)][:10])
    except Exception as error:
        result["error"] = str(error)[:300]
    return result


def main():
    source = (ROOT / "macos/client/Sources/UI/Extensions/ExtensionsView.swift").read_text()
    tail = source[source.index("private let communityPresets:"):]
    entries = re.findall(r'name: "([^"]+)",\s*targetURL: "([^"]+)"', tail)
    entries += [
        ("Default repository", "https://raw.githubusercontent.com/recloudstream/extensions/master/repo.json"),
        ("CSX", "https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json"),
        ("Phisher", "https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json"),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(probe, entries))
    output = {"observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "Public repository manifests and plugin lists only; no extension installation or media playback.", "results": results}
    OUTPUT.write_text(json.dumps(output, indent=2) + "\n")
    for result in results:
        print(json.dumps(result))


if __name__ == "__main__":
    main()
