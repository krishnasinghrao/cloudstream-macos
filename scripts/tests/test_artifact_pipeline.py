"""Native closure verification and the single dist publisher, on real Mach-O files and bundles."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / "scripts/verify_macho_closure.py"
PUBLISH = ROOT / "scripts/publish_artifact.sh"


def sh(*args, **kwargs):
    return subprocess.run(list(map(str, args)), capture_output=True, text=True, **kwargs)


def clang(output, source, *flags):
    result = sh("xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0", *flags, "-o", output, source)
    if result.returncode != 0:
        raise unittest.SkipTest(f"clang unavailable: {result.stderr[:200]}")


class Workspace(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        (self.root / "lib.c").write_text("int value(void) { return 7; }\n")
        (self.root / "main.c").write_text("int value(void); int main(void) { return value() == 7 ? 0 : 1; }\n")

    def bundle(self, name="CloudStream.app", lib_install="@rpath/libdep.dylib", rpath="@executable_path/../Frameworks",
               lib_min="15.0"):
        """A minimal real bundle: an executable linking one bundled dylib."""
        contents = self.root / name / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Frameworks").mkdir()
        lib = contents / "Frameworks" / "libdep.dylib"
        result = sh("xcrun", "clang", "-arch", "arm64", f"-mmacosx-version-min={lib_min}", "-dynamiclib",
                    "-install_name", lib_install, "-o", lib, self.root / "lib.c")
        if result.returncode != 0:
            raise unittest.SkipTest(f"clang unavailable: {result.stderr[:200]}")
        clang(contents / "MacOS" / "CloudStream", self.root / "main.c", f"-L{lib.parent}", "-ldep", "-Wl,-rpath," + rpath)
        (contents / "Info.plist").write_text(textwrap.dedent('''\
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleExecutable</key><string>CloudStream</string>
              <key>CFBundleIdentifier</key><string>test.cloudstream.fixture</string>
              <key>CFBundleName</key><string>CloudStream</string>
              <key>CFBundleShortVersionString</key><string>9.9</string>
              <key>CFBundleVersion</key><string>1</string>
              <key>LSMinimumSystemVersion</key><string>15.0</string>
            </dict></plist>
            '''))
        return self.root / name

    def sign(self, app):
        self.assertEqual(sh("codesign", "--force", "--sign", "-", app / "Contents/Frameworks/libdep.dylib").returncode, 0)
        result = sh("codesign", "--force", "--sign", "-", app)
        self.assertEqual(result.returncode, 0, result.stderr)


class ClosureTests(Workspace):
    def verify(self, app, *extra):
        return sh("python3", VERIFY, app, "--min-os", "15.0", "--arch", "arm64", *extra)

    def test_self_contained_bundle_passes_and_is_inventoried(self):
        app = self.bundle()
        inventory = self.root / "inventory.json"
        result = self.verify(app, "--inventory", inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sh(app / "Contents/MacOS/CloudStream").returncode, 0, "the fixture really loads its library")
        entries = {entry["path"]: entry for entry in json.loads(inventory.read_text())["binaries"]}
        self.assertEqual(set(entries), {"Contents/MacOS/CloudStream", "Contents/Frameworks/libdep.dylib"})
        executable = entries["Contents/MacOS/CloudStream"]
        self.assertEqual(executable["dependencies"][0]["path"], "Contents/Frameworks/libdep.dylib")
        self.assertEqual(len(executable["sha256"]), 64)
        self.assertEqual(executable["minimumOS"], "15.0")

    def test_unresolved_relative_dependency_fails(self):
        app = self.bundle(rpath="@executable_path/../Missing")
        result = self.verify(app)
        self.assertEqual(result.returncode, 1)
        self.assertIn("@rpath/libdep.dylib does not resolve", result.stderr)

    def test_loader_path_dependency_is_resolved_relative_to_its_loader(self):
        app = self.bundle(lib_install="@loader_path/../Frameworks/libdep.dylib", rpath="@executable_path/../Unused")
        self.assertEqual(self.verify(app).returncode, 0)
        shutil.move(app / "Contents/Frameworks/libdep.dylib", app / "Contents/libdep.dylib")
        self.assertIn("does not resolve", self.verify(app).stderr)

    def test_dependency_and_run_path_outside_the_bundle_fail(self):
        outside = self.root / "outside"
        outside.mkdir()
        app = self.bundle(lib_install=str(outside / "libdep.dylib"))
        shutil.copy2(app / "Contents/Frameworks/libdep.dylib", outside / "libdep.dylib")
        result = self.verify(app)
        self.assertEqual(result.returncode, 1)
        self.assertIn("resolves outside the bundle", result.stderr)
        other = self.bundle(name="Other.app", rpath=str(outside))
        result = self.verify(other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("run path leaves the bundle", result.stderr)

    def test_newer_minimum_os_and_wrong_architecture_fail(self):
        app = self.bundle(lib_min="26.0")
        result = self.verify(app)
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires macOS 26.0", result.stderr)
        self.assertIn("lacks x86_64", sh("python3", VERIFY, self.bundle(name="Arch.app"), "--arch", "x86_64").stderr)

    def test_directory_without_native_code_is_an_error_not_a_pass(self):
        empty = self.root / "empty"
        empty.mkdir()
        (empty / "notes.txt").write_text("no binaries")
        self.assertEqual(self.verify(empty).returncode, 1)


class MediaStagingTests(Workspace):
    """A compiled stand-in media stack with the dependency shapes real ones have."""

    def prefix(self, util_min="15.0"):
        prefix = self.root / "media-stack"
        (prefix / "lib").mkdir(parents=True)
        (prefix / "bin").mkdir()
        (self.root / "util.c").write_text("int util(void) { return 3; }\n")
        (self.root / "codec.c").write_text("int util(void); int codec(void) { return util() + 4; }\n")
        (self.root / "mpv.c").write_text("int codec(void); int mpv(void) { return codec(); }\n")
        (self.root / "ffmpeg.c").write_text("int codec(void); int main(void) { return codec() == 7 ? 0 : 9; }\n")
        lib = prefix / "lib"
        def dylib(name, source, install, *flags, minimum="15.0"):
            result = sh("xcrun", "clang", "-arch", "arm64", f"-mmacosx-version-min={minimum}", "-dynamiclib",
                        "-install_name", install, "-o", lib / name, self.root / source, *flags)
            if result.returncode != 0:
                raise unittest.SkipTest(f"clang unavailable: {result.stderr[:200]}")
        # libutil: referenced by its sibling through @loader_path (the case the old script skipped).
        dylib("libutil.1.dylib", "util.c", "@loader_path/libutil.1.dylib", minimum=util_min)
        # libcodec: an absolute install name, as a prefix build produces.
        dylib("libcodec.2.dylib", "codec.c", str(lib / "libcodec.2.dylib"), f"-L{lib}", "-lutil.1")
        # libmpv: finds libcodec through @rpath with a relative run path.
        sh("install_name_tool", "-id", "@rpath/libcodec.2.dylib", lib / "libcodec.2.dylib")
        dylib("libmpv.2.dylib", "mpv.c", str(lib / "libmpv.2.dylib"), f"-L{lib}", "-lcodec.2", "-Wl,-rpath,@loader_path")
        sh("install_name_tool", "-id", str(lib / "libcodec.2.dylib"), lib / "libcodec.2.dylib")
        # ffmpeg: absolute dependency plus an absolute run path into the prefix.
        clang(prefix / "bin/ffmpeg", self.root / "ffmpeg.c", f"-L{lib}", "-lcodec.2", f"-Wl,-rpath,{lib}")
        return prefix

    def stage(self, prefix, staging, *extra):
        return sh("python3", ROOT / "scripts/stage_media.py", "stage", prefix / "bin/ffmpeg", prefix / "lib/libmpv.2.dylib", staging, *extra)

    def check(self, prefix, staging):
        return sh("python3", ROOT / "scripts/stage_media.py", "check", prefix / "bin/ffmpeg", prefix / "lib/libmpv.2.dylib", staging)

    def test_closure_is_complete_relocatable_and_recorded(self):
        prefix = self.prefix()
        staging = self.root / "Resources"
        result = sh("bash", ROOT / "scripts/bundle_media.sh", prefix / "bin/ffmpeg", prefix / "lib/libmpv.2.dylib", staging)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in (staging / "Frameworks").iterdir()), ["libcodec.2.dylib", "libutil.1.dylib"])
        self.assertEqual(self.check(prefix, staging).returncode, 0)
        manifest = json.loads((staging / "media-manifest.json").read_text())
        self.assertEqual(set(manifest["staged"]), {"Binaries/ffmpeg", "Binaries/libmpv.dylib",
                                                    "Frameworks/libcodec.2.dylib", "Frameworks/libutil.1.dylib"})
        # Nothing may still point at the build prefix: remove it, move the result, run it.
        moved = self.root / "elsewhere/Resources"
        moved.parent.mkdir()
        shutil.move(staging, moved)
        shutil.rmtree(prefix)
        self.assertEqual(sh(moved / "Binaries/ffmpeg", "-version").returncode, 0, "the staged ffmpeg loads only what was staged")
        commands = sh("otool", "-l", moved / "Binaries/ffmpeg").stdout
        self.assertNotIn(str(prefix), commands, "the absolute run path into the prefix was removed")
        self.assertEqual(sh("python3", VERIFY, moved, "--min-os", "15.0", "--arch", "arm64").returncode, 0)
        self.assertEqual(sh("codesign", "--verify", moved / "Binaries/ffmpeg").returncode, 0)

    def test_unresolved_dependency_fails_and_keeps_the_previous_staging(self):
        prefix = self.prefix()
        staging = self.root / "Resources"
        self.assertEqual(self.stage(prefix, staging).returncode, 0)
        before = (staging / "media-manifest.json").read_text()
        (prefix / "lib/libutil.1.dylib").unlink()
        result = self.stage(prefix, staging)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not resolve", result.stderr)
        self.assertEqual((staging / "media-manifest.json").read_text(), before)
        self.assertTrue((staging / "Frameworks/libutil.1.dylib").exists(), "a failed run does not strip the last good closure")
        self.assertFalse(list(staging.glob(".media-staging-*")))

    def test_newer_minimum_os_in_the_closure_fails(self):
        prefix = self.prefix(util_min="26.0")
        result = self.stage(prefix, self.root / "Resources", "--min-os", "15.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires macOS 26.0", result.stderr)
        self.assertFalse((self.root / "Resources/Binaries").exists())

    def test_stale_or_unrecorded_staging_is_not_accepted(self):
        prefix = self.prefix()
        staging = self.root / "Resources"
        # An ffmpeg that merely exists proves nothing.
        (staging / "Binaries").mkdir(parents=True)
        shutil.copy2(prefix / "bin/ffmpeg", staging / "Binaries/ffmpeg")
        missing = self.check(prefix, staging)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("no media manifest", missing.stderr)
        self.assertEqual(self.stage(prefix, staging).returncode, 0)
        self.assertEqual(self.check(prefix, staging).returncode, 0)
        # A source rebuilt since, a changed staged file and a stray library are each detected.
        with (staging / "Frameworks/libutil.1.dylib").open("ab") as handle:
            handle.write(b"x")
        self.assertIn("staged file changed", self.check(prefix, staging).stderr)
        self.assertEqual(self.stage(prefix, staging).returncode, 0)
        (staging / "Frameworks/libstray.dylib").write_bytes(b"left over from another build")
        self.assertIn("unrecorded file", self.check(prefix, staging).stderr)
        self.assertEqual(self.stage(prefix, staging).returncode, 0)
        self.assertFalse((staging / "Frameworks/libstray.dylib").exists(), "restaging replaces the directory, not merges into it")
        (self.root / "ffmpeg.c").write_text("int codec(void); int main(void) { return codec() == 7 ? 0 : 8; }\n")
        clang(prefix / "bin/ffmpeg", self.root / "ffmpeg.c", f"-L{prefix / 'lib'}", "-lcodec.2", f"-Wl,-rpath,{prefix / 'lib'}")
        self.assertIn("ffmpeg source changed", self.check(prefix, staging).stderr)


class BundleSigningAndVerificationTests(Workspace):
    """The helpers both build scripts share, on a bundle shaped like the real one."""

    def full_bundle(self, outside_dependency=False):
        app = self.bundle()
        resources = app / "Contents/Resources"
        (resources / "Binaries").mkdir(parents=True)
        (resources / "runtime/bin").mkdir(parents=True)
        (self.root / "tool.c").write_text("int main(void) { return 0; }\n")
        clang(resources / "Binaries/ffmpeg", self.root / "tool.c")
        clang(resources / "runtime/bin/java", self.root / "tool.c")
        if outside_dependency:
            outside = self.root / "homebrew"
            outside.mkdir()
            sh("xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0", "-dynamiclib", "-install_name",
               str(outside / "libbrew.dylib"), "-o", outside / "libbrew.dylib", self.root / "lib.c")
            sh("xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0", "-dynamiclib", "-install_name",
               "@rpath/libmpv.dylib", "-o", resources / "Binaries/libmpv.dylib", self.root / "lib.c", f"-L{outside}", "-lbrew")
        else:
            sh("xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0", "-dynamiclib", "-install_name",
               "@rpath/libmpv.dylib", "-o", resources / "Binaries/libmpv.dylib", self.root / "lib.c")
        return app

    def helper(self, app, mode, identity="-"):
        script = f'''set -euo pipefail
source "{ROOT}/scripts/lib_artifact.sh"
sign_bundle "{app}" "{identity}"
verify_bundle "{app}" {mode}
echo "closure=$NATIVE_CLOSURE"
'''
        return sh("bash", "-c", script)

    def test_every_nested_binary_is_signed_and_the_bundle_verifies(self):
        app = self.full_bundle()
        result = self.helper(app, "distribution")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("closure=verified", result.stdout)
        for nested in ("Contents/Frameworks/libdep.dylib", "Contents/Resources/Binaries/ffmpeg",
                       "Contents/Resources/Binaries/libmpv.dylib", "Contents/Resources/runtime/bin/java"):
            self.assertEqual(sh("codesign", "--verify", "--strict", app / nested).returncode, 0, nested)
        inventory = json.loads((app.parent / "native-inventory.json").read_text())
        self.assertEqual(len(inventory["binaries"]), 5)

    def test_outside_dependency_is_development_only(self):
        app = self.full_bundle(outside_dependency=True)
        development = self.helper(app, "development")
        self.assertEqual(development.returncode, 0, development.stderr)
        self.assertIn("closure=not-portable", development.stdout)
        self.assertIn("not portable", development.stderr)
        distribution = self.helper(app, "distribution")
        self.assertNotEqual(distribution.returncode, 0)
        self.assertIn("must load only from its bundle", distribution.stderr)

    def test_failed_signature_and_missing_entry_point_fail(self):
        app = self.full_bundle()
        bad = self.helper(app, "development", identity="No Such Identity (XXXXXXXXXX)")
        self.assertNotEqual(bad.returncode, 0, "a signing failure is never ignored")
        (app / "Contents/Resources/Binaries/ffmpeg").unlink()
        missing = self.helper(app, "development")
        self.assertNotEqual(missing.returncode, 0)

    def test_distribution_packaging_refuses_to_start_without_usable_credentials(self):
        package = ROOT / "scripts/package_app.sh"
        env = {k: v for k, v in os.environ.items() if not k.startswith("CS_")}
        dist = self.root / "dist"
        missing = sh("bash", package, "--distribution", env={**env, "CS_DIST_DIR": str(dist)})
        self.assertEqual(missing.returncode, 1)
        self.assertIn("CS_SIGNING_IDENTITY", missing.stderr)
        absent = sh("bash", package, "--distribution", env={**env, "CS_DIST_DIR": str(dist),
                    "CS_SIGNING_IDENTITY": "Developer ID Application: Nobody (0000000000)", "CS_KEYCHAIN_PROFILE": "none"})
        self.assertEqual(absent.returncode, 1)
        self.assertIn("signing identity not found", absent.stderr)
        self.assertNotIn("Building daemon", missing.stdout + absent.stdout, "it fails before building anything")
        self.assertFalse(dist.exists(), "and before anything could be published")
        self.assertEqual(sh("bash", package, "--bogus").returncode, 2)


class PublisherTests(Workspace):
    def publish(self, app, build_id, mode="development", extra_env=None, dmg=None):
        dist = self.root / "dist"
        command = ["bash", PUBLISH, "--app", app, "--mode", mode, "--dist", dist, "--build-id", build_id]
        if dmg:
            command += ["--dmg", dmg]
        return sh(*command, env={**os.environ, **(extra_env or {})}), dist

    def test_publish_switches_one_link_and_records_what_was_published(self):
        app = self.bundle()
        self.sign(app)
        dmg = self.root / "CloudStream.dmg"
        dmg.write_bytes(b"dmg-bytes")
        result, dist = self.publish(app, "build-1", dmg=dmg)
        self.assertEqual(result.returncode, 0, result.stderr)
        generation = dist / "generations/build-1"
        self.assertIn(f"generation={generation}", result.stdout)
        self.assertEqual(os.readlink(dist / "current"), "generations/build-1")
        self.assertEqual(os.readlink(dist / "CloudStream.app"), "current/CloudStream.app")
        self.assertEqual((dist / "CloudStream.dmg").read_bytes(), b"dmg-bytes")
        self.assertEqual(sh(dist / "CloudStream.app/Contents/MacOS/CloudStream").returncode, 0)
        self.assertEqual(sh("codesign", "--verify", "--deep", "--strict", dist / "CloudStream.app").returncode, 0)
        info = json.loads((dist / "BUILD_INFO.json").read_text())
        self.assertEqual(info["buildID"], "build-1")
        self.assertEqual(info["signingMode"], "development")
        self.assertEqual(info["signingAuthority"], "ad-hoc")
        self.assertEqual(info["minimumOS"], "15.0")
        self.assertEqual(info["architecture"], ["arm64"])
        self.assertEqual(len(info["hashes"]["executable"]), 64)
        self.assertEqual(len(info["hashes"]["frameworks"]), 64)
        self.assertEqual(len(info["hashes"]["dmg"]), 64)
        self.assertEqual(info["nativeClosure"], "unchecked")
        self.assertEqual(info["provenance"], {})
        self.assertFalse(list((dist / "generations").glob(".staging-*")))
        self.assertFalse((dist / ".publish.lock").exists())

        # A later generation without a DMG must not keep offering the old one.
        result, _ = self.publish(app, "build-2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(dist / "current"), "generations/build-2")
        self.assertFalse((dist / "CloudStream.dmg").is_symlink())
        self.assertTrue((dist / "generations/build-1/CloudStream.dmg").exists(), "the last good generation is kept")

    def test_unverified_input_never_reaches_dist_and_the_previous_generation_stays(self):
        good = self.bundle()
        self.sign(good)
        result, dist = self.publish(good, "good")
        self.assertEqual(result.returncode, 0, result.stderr)

        unsigned = self.bundle(name="Unsigned/CloudStream.app")
        sh("codesign", "--remove-signature", unsigned / "Contents/MacOS/CloudStream")
        result, _ = self.publish(unsigned, "unsigned")
        self.assertNotEqual(result.returncode, 0)

        tampered = self.bundle(name="Tampered/CloudStream.app")
        self.sign(tampered)
        (tampered / "Contents/Resources").mkdir()
        (tampered / "Contents/Resources/added-after-signing.txt").write_text("changed")
        result, _ = self.publish(tampered, "tampered")
        self.assertNotEqual(result.returncode, 0)

        # A development (ad-hoc) app can never be published as a distribution build.
        result = sh("bash", PUBLISH, "--app", good, "--mode", "distribution", "--dist", dist, "--build-id", "release",
                    "--closure", "verified")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Developer ID", result.stderr)

        self.assertEqual(os.readlink(dist / "current"), "generations/good")
        self.assertEqual(sorted(p.name for p in (dist / "generations").iterdir()), ["good"])
        self.assertFalse((dist / ".publish.lock").exists())

    def test_provenance_files_travel_with_the_generation_and_distribution_needs_a_verified_closure(self):
        app = self.bundle()
        self.sign(app)
        sbom = self.root / "sbom.cdx.json"
        sbom.write_text('{"components": []}')
        dist = self.root / "dist"
        result = sh("bash", PUBLISH, "--app", app, "--mode", "development", "--dist", dist, "--build-id", "with-sbom",
                    "--closure", "not-portable", "--attach", sbom)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads((dist / "BUILD_INFO.json").read_text())
        self.assertEqual(info["nativeClosure"], "not-portable")
        self.assertEqual(list(info["provenance"]), ["sbom.cdx.json"])
        self.assertEqual((dist / "current/provenance/sbom.cdx.json").read_text(), '{"components": []}')
        missing = sh("bash", PUBLISH, "--app", app, "--mode", "development", "--dist", dist, "--build-id", "bad",
                     "--attach", self.root / "absent.json")
        self.assertNotEqual(missing.returncode, 0)
        refused = sh("bash", PUBLISH, "--app", app, "--mode", "distribution", "--dist", dist, "--build-id", "rel",
                     "--closure", "not-portable")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("verified native closure", refused.stderr)
        self.assertEqual(os.readlink(dist / "current"), "generations/with-sbom")

    def test_legacy_real_directory_is_kept_as_a_generation_not_deleted(self):
        app = self.bundle()
        self.sign(app)
        dist = self.root / "dist"
        (dist / "CloudStream.app/Contents").mkdir(parents=True)
        (dist / "CloudStream.app/Contents/old.txt").write_text("previous publisher")
        (dist / "BUILD_INFO.json").write_text("{}")
        result, _ = self.publish(app, "new")
        self.assertEqual(result.returncode, 0, result.stderr)
        legacy = [p for p in (dist / "generations").iterdir() if p.name.startswith("legacy-")]
        self.assertEqual(len(legacy), 1)
        self.assertEqual((legacy[0] / "CloudStream.app/Contents/old.txt").read_text(), "previous publisher")
        self.assertTrue((dist / "CloudStream.app").is_symlink())

    def test_concurrent_publishers_never_mix_generations(self):
        apps = []
        for index in range(3):
            app = self.bundle(name=f"src{index}/CloudStream.app")
            (app / "Contents/Resources").mkdir()
            (app / "Contents/Resources/marker.txt").write_text(f"build-{index}")
            self.sign(app)
            apps.append(app)
        dist = self.root / "dist"
        processes = [subprocess.Popen(["bash", str(PUBLISH), "--app", str(app), "--mode", "development", "--dist", str(dist),
                                       "--build-id", f"build-{index}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for index, app in enumerate(apps)]
        for process in processes:
            _, stderr = process.communicate(timeout=120)
            self.assertEqual(process.returncode, 0, stderr)
        current = os.readlink(dist / "current").split("/")[-1]
        info = json.loads((dist / "BUILD_INFO.json").read_text())
        marker = (dist / "CloudStream.app/Contents/Resources/marker.txt").read_text()
        self.assertEqual(info["buildID"], current)
        self.assertEqual(marker, current, "the app and its metadata come from one generation")
        self.assertEqual(len([p for p in (dist / "generations").iterdir() if p.is_dir()]), 3)

    def test_lock_times_out_on_a_live_holder_and_recovers_from_a_dead_one(self):
        app = self.bundle()
        self.sign(app)
        dist = self.root / "dist"
        (dist / ".publish.lock").mkdir(parents=True)
        (dist / ".publish.lock/pid").write_text(str(os.getpid()))
        result, _ = self.publish(app, "blocked", extra_env={"CS_PUBLISH_LOCK_TIMEOUT": "2"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("another publisher holds", result.stderr)
        self.assertFalse((dist / "current").exists())
        self.assertTrue((dist / ".publish.lock").exists(), "a lock owned by someone else is not removed")
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        (dist / ".publish.lock/pid").write_text(str(dead.pid))
        result, _ = self.publish(app, "recovered", extra_env={"CS_PUBLISH_LOCK_TIMEOUT": "5"})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_old_generations_are_pruned_but_the_last_good_ones_remain(self):
        app = self.bundle()
        self.sign(app)
        for index in range(4):
            result, dist = self.publish(app, f"g{index}", extra_env={"CS_DIST_KEEP_GENERATIONS": "2"})
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in (dist / "generations").iterdir()), ["g2", "g3"])


if __name__ == "__main__":
    unittest.main()
