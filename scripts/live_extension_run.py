"""Live extension run (RT-17): the published app's own engine, on a copy of
this Mac's engine data (installed extensions), runs search -> details -> links
for every provider and writes:

  <work>/report.json        per-provider counts and errors
  /tmp/cs_live_links.json   the first links of each provider, for the gated
                            player test testLiveExtensionStreamsReachTheirFirstFrame

The real data root is only read (copied); nothing is written back.

  python3 scripts/live_extension_run.py [query]          engine alone
  python3 scripts/live_extension_run.py --app [query]    the whole app, isolated:
      its WebKit solves challenges, runs WebViewResolver pages and extension
      WebViews (a window opens while it runs; the app quits at the end)
  python3 scripts/live_extension_run.py --recheck [query]
      first runs Check for Changes (RT-08) on every extension installed
      without a publisher hash, then the search as above
"""
import json, os, secrets, shutil, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
R = os.path.realpath(os.path.join(REPO, "dist/CloudStream.app/Contents/Resources"))
APP_MODE = "--app" in sys.argv
if APP_MODE: sys.argv.remove("--app")
RECHECK = "--recheck" in sys.argv
if RECHECK: sys.argv.remove("--recheck")
S = tempfile.mkdtemp(prefix="cloudstream-live-")
# The isolated app keeps its engine data under <root>/engine.
home = os.path.join(S, "engine" if APP_MODE else "home")
shutil.copytree(os.path.expanduser("~/.cloudstream-macos"), home, ignore=shutil.ignore_patterns("daemon.lock", "logs", "tmp"))
os.makedirs(os.path.join(home, "tmp"), exist_ok=True)
token = secrets.token_hex(32)
options = {"isolation": "worker", "safeMode": False, "policy": {"allowCommunityTier": True, "allowLocalObservation": True,
           "allowUserRepositories": True, "allowDeveloperExtensions": True, "requireSandbox": False, "safeModeOnly": False,
           "managed": False, "blockedRepositories": [], "pinnedRepositoryKeys": {}}}
log = open(os.path.join(S, "engine.log"), "wb")
if APP_MODE:
    status, endpoint_file = os.path.join(S, "status.json"), os.path.join(S, "endpoint.json")
    env = dict(os.environ, CS_IN_MEMORY_DB="1", CS_TEST_ROOT=S, CS_SMOKE_STATUS_FILE=status, CS_LIVE_ENDPOINT_FILE=endpoint_file)
    engine = subprocess.Popen([os.path.join(os.path.dirname(R), "MacOS/CloudStream")], env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(600):
        if os.path.exists(endpoint_file): break
        time.sleep(0.25)
    endpoint = json.load(open(endpoint_file))
    port, token = endpoint["port"], endpoint["token"]
else:
    port = 50000 + secrets.randbelow(10000)
    engine = subprocess.Popen(["runtime/bin/java", "-XX:TieredStopAtLevel=1", "-Xms16m", "-Xmx192m", "-XX:+UseSerialGC",
        f"-XX:SharedArchiveFile={R}/tools/daemon.jsa", f"-Dcs.cloudstream.home={home}", f"-Djava.io.tmpdir={home}/tmp",
        "-jar", "tools/daemon.jar", str(port)], cwd=R, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
    engine.stdin.write((token + "\n" + json.dumps(options) + "\n").encode()); engine.stdin.flush()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def call(path, body=None, timeout=200):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/{path}", data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with opener.open(req, timeout=timeout) as r: return r.read()
report = {}
try:
    for _ in range(200):
        try:
            h = json.loads(call("health", timeout=2))
            if (h.get("extensions") or {}).get("phase") in ("ready", "safe_mode"): break
        except Exception: pass
        time.sleep(0.25)
    report["health"] = h.get("extensions")
    plugins = json.loads(call("plugins"))
    report["plugins"] = [{"name": p.get("name"), "version": p.get("version"), "state": p.get("state")} for p in plugins]
    if RECHECK:
        report["recheck"] = {}
        for p in plugins:
            if p.get("publisherHash") or p.get("verificationMode") != "local_observation": continue
            row = {"before": p.get("sha"), "version": p.get("version")}
            started = time.time()
            try:
                after = json.loads(call("plugins/update", {"installationId": p["id"]}, timeout=300))
                row.update(after=after.get("sha"), changed=after.get("sha") != p.get("sha"), state=after.get("state"),
                           previousVersion=after.get("previousVersion"), lastError=after.get("lastError"))
            except urllib.error.HTTPError as ex:
                row["error"] = f"{ex.code} {ex.read().decode(errors='replace')[:300]}"
            except Exception as ex:
                row["error"] = str(ex)[:300]
            row["seconds"] = round(time.time() - started, 1)
            report["recheck"][p.get("name")] = row
        report["plugins"] = [{"name": p.get("name"), "version": p.get("version"), "state": p.get("state")} for p in json.loads(call("plugins"))]
    query = sys.argv[1] if len(sys.argv) > 1 else "Inception"
    results = {}
    raw = call("search/stream?" + urllib.parse.urlencode({"q": query}), timeout=200).decode()
    for line in raw.splitlines():
        try: e = json.loads(line)
        except ValueError: continue
        if e.get("type") == "provider_result": results.setdefault(e.get("provider"), []).extend(e.get("results", []))
        if e.get("type") == "provider_error": report.setdefault("searchErrors", {})[e.get("provider")] = e.get("error")
    report["search"] = {k: len(v) for k, v in results.items()}
    report["providers"] = {}
    for provider, items in results.items():
        movie = next((i for i in items if i.get("type") in ("Movie", "AnimeMovie")), items[0] if items else None)
        if not movie: continue
        row = {"title": movie.get("name")}
        try:
            d = json.loads(call("details?" + urllib.parse.urlencode({"plugin": movie.get("providerId") or provider, "url": movie["url"]})))
            data = d.get("movieData") or ((d.get("episodes") or [{}])[0].get("data"))
            row["details"] = "pass"
            l = json.loads(call("links", {"plugin": movie.get("providerId") or provider, "data": data}))
            row["links"] = len(l.get("links", [])); row["subtitles"] = len(l.get("subtitles", []))
            row["top"] = l.get("links", [])[:6]
        except Exception as ex:
            row["error"] = str(ex)[:300]
        report["providers"][provider] = row
finally:
    engine.terminate(); engine.wait(15); log.close()
json.dump(report, open(os.path.join(S, "report.json"), "w"), indent=1)
json.dump([{"provider": p, "link": l} for p, row in report["providers"].items() for l in row.get("top", [])[:3]],
          open("/tmp/cs_live_links.json", "w"))
print("report:", os.path.join(S, "report.json"))
print(json.dumps({k: v for k, v in report.items() if k != "providers"}, indent=1))
for p, r in report["providers"].items(): print(p, {k: v for k, v in r.items() if k != "top"})
