"""Catalog-wide compatibility run (Compatibility-Fix-Plan C0/C1).

Installs every extension of the given repositories into a throwaway engine
home and records, per extension and provider, whether it installs, starts,
searches, opens a title and resolves links, with the engine's typed failure
code for each step. The packaged app's own engine runs it (dist/), with the
same sandboxed workers the app uses. Nothing is read from or written to
~/.cloudstream-macos.

  python3 scripts/catalog_compat_run.py --wiki                 every repository on the wiki's list
  python3 scripts/catalog_compat_run.py URL [URL …]            these repositories (repo.json addresses)
      --query TEXT     search text (default: "Inception")
      --out DIR        where report.json and summary.md go (default: a new temp directory)
      --limit N        install at most N extensions per repository (quick checks)

Community extensions are third-party code: they run here exactly as they
would in the app, inside its sandboxed workers.
"""
import argparse, collections, json, os, re, secrets, shutil, subprocess, sys, tempfile, time
import urllib.error, urllib.parse, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCES = os.path.realpath(os.path.join(REPO, "dist/CloudStream.app/Contents/Resources"))
WIKI = "https://cloudstream.miraheze.org/wiki/List_of_extensions?action=raw"


def wiki_repositories():
    raw = urllib.request.urlopen(urllib.request.Request(WIKI, headers={"User-Agent": "Mozilla/5.0"}), timeout=60).read().decode()
    urls = []
    # "Direct install" cells: cloudstreamrepo:// links, or a plain repo.json address.
    found = re.findall(r"cloudstreamrepo://(\S+?)[\s\]]", raw) + \
        [m.removeprefix("https://") for m in re.findall(r"^\|\s*(?:rowspan=\"\d+\"\s*\|)?\s*(https://\S+?/repo\.json)\s*$", raw, re.M)]
    for match in found:
        url = "https://" + match
        if url not in urls: urls.append(url)
    return urls


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repositories", nargs="*")
    parser.add_argument("--wiki", action="store_true")
    parser.add_argument("--query", default="Inception")
    parser.add_argument("--out")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()
    repositories = (wiki_repositories() if args.wiki else []) + args.repositories
    if not repositories: parser.error("give repository URLs or --wiki")
    if not os.path.isdir(RESOURCES): sys.exit("build the app first: make build")

    out = args.out or tempfile.mkdtemp(prefix="cloudstream-catalog-")
    os.makedirs(out, exist_ok=True)
    home = tempfile.mkdtemp(prefix="cloudstream-catalog-home-")
    os.makedirs(os.path.join(home, "tmp"), exist_ok=True)
    token, port = secrets.token_hex(32), 50000 + secrets.randbelow(10000)
    options = {"isolation": "worker", "safeMode": False, "policy": {"allowCommunityTier": True, "allowLocalObservation": True,
               "allowUserRepositories": True, "allowDeveloperExtensions": False, "requireSandbox": True, "safeModeOnly": False,
               "managed": False, "blockedRepositories": [], "pinnedRepositoryKeys": {}}}
    log = open(os.path.join(out, "engine.log"), "wb")
    engine = subprocess.Popen(["runtime/bin/java", "-XX:TieredStopAtLevel=1", "-Xms16m", "-Xmx192m", "-XX:+UseSerialGC",
        f"-XX:SharedArchiveFile={RESOURCES}/tools/daemon.jsa", "-Djava.net.useSystemProxies=true",
        f"-Dcs.cloudstream.home={home}", f"-Djava.io.tmpdir={home}/tmp", "-jar", "tools/daemon.jar", str(port)],
        cwd=RESOURCES, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
    engine.stdin.write((token + "\n" + json.dumps(options) + "\n").encode()); engine.stdin.flush()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def call(path, body=None, timeout=300):
        request = urllib.request.Request(f"http://127.0.0.1:{port}/{path}",
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with opener.open(request, timeout=timeout) as response: return json.loads(response.read() or b"null")

    def attempt(path, body=None, timeout=300):
        """(value, None) or (None, {code, message}) — typed engine failures keep their code."""
        try: return call(path, body, timeout), None
        except urllib.error.HTTPError as error:
            text = error.read().decode(errors="replace")
            try:
                payload = json.loads(text)
                failure = payload.get("failure") or {}
                return None, {"code": failure.get("code") or payload.get("code") or f"http_{error.code}",
                              "message": failure.get("publicMessage") or payload.get("detail") or payload.get("error"),
                              "cause": failure.get("redactedCause")}
            except ValueError:
                return None, {"code": f"http_{error.code}", "message": text[:300]}
        except Exception as error:
            return None, {"code": "client_error", "message": str(error)[:300]}

    report = {"startedAt": time.strftime("%Y-%m-%dT%H:%M:%S"), "query": args.query, "repositories": {}, "extensions": {}, "providers": {}}
    try:
        for _ in range(240):
            try:
                if (call("health", timeout=2).get("extensions") or {}).get("phase") in ("ready", "safe_mode"): break
            except Exception: pass
            time.sleep(0.25)
        for url in repositories:
            print("repository", url, flush=True)
            for _ in range(4):  # the engine admits a few syncs, then one every two seconds
                synced, failure = attempt("repos/sync", {"repoUrl": url})
                if not failure or failure["code"] != "rate_limited": break
                time.sleep(2.5)
            if failure: report["repositories"][url] = {"sync": failure}; continue
            attempt("repos/consent", {"repoUrl": url, "allow": True})
            catalog, failure = attempt("repos/plugins?" + urllib.parse.urlencode({"repoUrl": url}))
            if failure: report["repositories"][url] = {"catalog": failure}; continue
            report["repositories"][url] = {"listed": len(catalog)}
            installed = 0
            for entry in catalog:
                if args.limit and installed >= args.limit: break
                key = f"{entry.get('repositoryUrl') or url}#{entry['internalName']}"
                row = {"name": entry.get("name"), "status": entry.get("status")}
                if not entry.get("installationAllowed"):
                    row["install"] = {"code": "blocked", "message": entry.get("installationBlockedReason")}
                else:
                    started = time.time()
                    plugin, failure = attempt("plugins/install", {"repoUrl": entry.get("repositoryUrl") or url,
                                                                  "internalName": entry["internalName"]}, timeout=600)
                    row["installSeconds"] = round(time.time() - started, 1)
                    row["install"] = failure or "ok"
                    installed += 1
                report["extensions"][key] = row
                print(" ", entry.get("name"), row["install"] if row["install"] == "ok" else row["install"].get("code"), flush=True)

        plugins, _ = attempt("plugins")
        for plugin in plugins or []:
            key = f"{plugin.get('repositoryUrl')}#{plugin.get('internalName')}"
            row = report["extensions"].setdefault(key, {"name": plugin.get("name")})
            compatibility = plugin.get("compatibility") or {}
            row.update(state=plugin.get("state"), lastError=plugin.get("lastError"), providers=plugin.get("providers"),
                       unsupported=plugin.get("unsupportedFeatures"), missing=compatibility.get("coreCode"))

        events, _ = None, None
        results = collections.defaultdict(list)
        try:
            raw = urllib.request.Request(f"http://127.0.0.1:{port}/search/stream?" + urllib.parse.urlencode({"q": args.query}),
                headers={"Authorization": f"Bearer {token}"})
            with opener.open(raw, timeout=900) as response:
                for line in response.read().decode().splitlines():
                    try: event = json.loads(line)
                    except ValueError: continue
                    provider = event.get("providerId") or event.get("provider")
                    if event.get("type") == "provider_result": results[provider].extend(event.get("results", []))
                    if event.get("type") == "provider_error":
                        report["providers"].setdefault(provider, {})["search"] = {"code": (event.get("failure") or {}).get("code") or "error",
                                                                                   "message": event.get("error")}
        except Exception as error:
            report["searchError"] = str(error)[:300]
        for provider, items in results.items():
            row = report["providers"].setdefault(provider, {})
            row["search"] = len(items)
            pick = next((i for i in items if i.get("type") in ("Movie", "AnimeMovie")), items[0] if items else None)
            if not pick: continue
            details, failure = attempt("details?" + urllib.parse.urlencode({"plugin": pick.get("providerId") or provider, "url": pick["url"]}))
            if failure: row["details"] = failure; continue
            row["details"] = "ok"
            data = details.get("movieData") or ((details.get("episodes") or [{}])[0].get("data"))
            if not data: row["links"] = {"code": "no_playable_data"}; continue
            links, failure = attempt("links", {"plugin": pick.get("providerId") or provider, "data": data}, timeout=600)
            row["links"] = failure or {"count": len(links.get("links", [])), "skipped": [s.get("reason") for s in links.get("skipped", [])],
                                       "failures": [f.get("code") for f in links.get("failures", [])]}
    finally:
        engine.terminate()
        try: engine.wait(20)
        except subprocess.TimeoutExpired: engine.kill()
        log.close()
        shutil.rmtree(home, ignore_errors=True)

    report["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    json.dump(report, open(os.path.join(out, "report.json"), "w"), indent=1)
    write_summary(report, os.path.join(out, "summary.md"))
    print("report:", os.path.join(out, "report.json"))
    print("summary:", os.path.join(out, "summary.md"))


def write_summary(report, path):
    extensions = report["extensions"]
    def code(value): return value if isinstance(value, str) else (value or {}).get("code", "missing")
    install = collections.Counter(code(row.get("install")) for row in extensions.values())
    states = collections.Counter(row.get("state") or "not installed" for row in extensions.values())
    missing = collections.Counter(symbol for row in extensions.values() for symbol in (row.get("missing") or []))
    providers = report["providers"]
    search = collections.Counter("ok" if isinstance(r.get("search"), int) and r["search"] > 0 else
                                 ("no results" if r.get("search") == 0 else code(r.get("search"))) for r in providers.values())
    details = collections.Counter(code(r.get("details")) for r in providers.values() if "details" in r)
    links = collections.Counter(("ok" if r["links"].get("count") else "no links") if isinstance(r.get("links"), dict) and "count" in r["links"]
                                else code(r.get("links")) for r in providers.values() if "links" in r)
    lines = [f"# Catalog compatibility run, {report['startedAt']}", "",
             f"{len(report['repositories'])} repositories, {len(extensions)} extensions, {len(providers)} providers searched for “{report['query']}”.", ""]
    for title, counter in (("Install", install), ("State after install", states), ("Search", search), ("Details", details), ("Links", links)):
        lines += [f"## {title}", "", "| Outcome | Count |", "|---|---|"] + [f"| {k} | {v} |" for k, v in counter.most_common()] + [""]
    lines += ["## Missing host symbols (start-up and provider code)", "", "| Symbol | Extensions |", "|---|---|"]
    lines += [f"| `{k}` | {v} |" for k, v in missing.most_common(40)] + [""]
    failing = [(r.get("name"), code(r.get("install"))) for r in extensions.values() if code(r.get("install")) not in ("ok",)]
    lines += ["## Extensions that did not install", "", "| Extension | Reason |", "|---|---|"]
    lines += [f"| {name} | {reason} |" for name, reason in sorted(failing, key=lambda x: str(x[0]))] + [""]
    open(path, "w").write("\n".join(lines))


if __name__ == "__main__":
    main()
