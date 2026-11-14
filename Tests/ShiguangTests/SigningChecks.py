#!/usr/bin/env python3
"""Exercise signature continuity with changed executable code and an impostor."""

import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


PROJECT = Path(__file__).resolve().parents[2]
HELPER = PROJECT / "scripts/local-signing.py"
IDENTIFIER = "dev.shiguang.screenshot"
SIGNING_HOME = Path(os.environ.get(
    "SHIGUANG_SIGNING_HOME",
    str(Path.home() / "Library/Application Support/ShiguangSigning"),
))


def run(arguments, success=True, env=None):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True, text=True, env=env)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result.stdout + result.stderr


def make_app(directory, version):
    app = directory / f"version-{version}.app"
    executable = app / "Contents/MacOS/Shiguang"
    executable.parent.mkdir(parents=True)
    resources = app / "Contents/Resources"
    resources.mkdir()
    (resources / "content.txt").write_text(f"Resource version {version}\n")
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({
            "CFBundleIdentifier": IDENTIFIER,
            "CFBundleExecutable": "Shiguang",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": str(version),
        }, stream)
    source = directory / f"version-{version}.c"
    source.write_text(f'#include <stdio.h>\nint main(void) {{ puts("Version {version}"); return 0; }}\n')
    run(["/usr/bin/clang", str(source), "-o", str(executable)])
    return app


def designated(app):
    output = run(["/usr/bin/codesign", "-d", "-r-", app])
    return next(line.split("designated => ", 1)[1]
                for line in output.splitlines() if "designated => " in line)


def main():
    run([sys.executable, HELPER, "check"])
    certificate_before = hashlib.sha256((SIGNING_HOME / "certificate.der").read_bytes()).hexdigest()
    manifest_before = (SIGNING_HOME / "identity.json").read_bytes()
    run([sys.executable, HELPER, "init"])
    assert manifest_before == (SIGNING_HOME / "identity.json").read_bytes()
    assert certificate_before == hashlib.sha256((SIGNING_HOME / "certificate.der").read_bytes()).hexdigest()
    print("PASS initialization_reuses_the_persistent_identity")

    with tempfile.TemporaryDirectory(prefix="shiguang-signing-checks-") as temporary:
        directory = Path(temporary)
        first, second = (make_app(directory, version) for version in (1, 2))
        for app in (first, second):
            run([sys.executable, HELPER, "sign", app])
        first_requirement, second_requirement = (designated(app) for app in (first, second))
        assert first_requirement == second_requirement
        assert "certificate leaf" in first_requirement and "cdhash" not in first_requirement
        first_code = (first / "Contents/MacOS/Shiguang").read_bytes()
        second_code = (second / "Contents/MacOS/Shiguang").read_bytes()
        assert hashlib.sha256(first_code).digest() != hashlib.sha256(second_code).digest()
        run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + first_requirement, second])
        run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + second_requirement, first])
        print("PASS changed_executables_preserve_the_same_designated_identity")
        for app in (first, second):
            assert "Signature=adhoc" not in run(["/usr/bin/codesign", "-d", "--verbose=4", app])
        print("PASS both_builds_have_certificate_backed_signatures")

        (second / "Contents/Resources/content.txt").write_text("Tampered resource\n")
        run(["/usr/bin/codesign", "--verify", "--strict", second], success=False)
        print("PASS altered_resources_are_rejected")

        impostor = make_app(directory, 3)
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", IDENTIFIER,
             "--requirements", "=designated => " + first_requirement, impostor])
        run(["/usr/bin/codesign", "--verify", "--strict", "-R=" + first_requirement, impostor], success=False)
        print("PASS same_identifier_and_claimed_requirement_cannot_impersonate_the_certificate")

        missing = directory / "missing-identity"
        env = dict(os.environ, SHIGUANG_SIGNING_HOME=str(missing))
        run([sys.executable, HELPER, "check"], success=False, env=env)
        assert not missing.exists()
        print("PASS missing_identity_fails_without_silent_regeneration")

        output = directory / "output"
        existing = output / "汪拍.app/Contents/MacOS/Shiguang"
        existing.parent.mkdir(parents=True)
        existing.write_bytes(b"Existing usable application")
        env.update(OUTPUT_DIR=str(output), BUILD_DIR=str(directory / "build"))
        run(["/bin/bash", PROJECT / "scripts/build.sh"], success=False, env=env)
        assert existing.read_bytes() == b"Existing usable application"
        assert not missing.exists() and not (directory / "build").exists()
        print("PASS missing_identity_preserves_the_existing_app")

        mismatched = directory / "mismatched-identity"
        mismatched.mkdir(mode=0o700)
        (mismatched / "identity.json").write_bytes(manifest_before)
        (mismatched / "certificate.der").write_bytes(b"Different certificate")
        (mismatched / "signing.keychain-db").touch(mode=0o600)
        (mismatched / "keychain-password").touch(mode=0o600)
        env = dict(os.environ, SHIGUANG_SIGNING_HOME=str(mismatched))
        run([sys.executable, HELPER, "check"], success=False, env=env)
        print("PASS certificate_mismatch_blocks_signing")
    print("8/8 signing checks passed")


if __name__ == "__main__":
    main()
