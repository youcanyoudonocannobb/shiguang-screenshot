#!/usr/bin/env python3
"""Keep one certificate-backed identity for local Shiguang updates."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile


IDENTIFIER = "dev.shiguang.screenshot"
SIGNING_HOME = Path(os.environ.get(
    "SHIGUANG_SIGNING_HOME",
    str(Path.home() / "Library/Application Support/ShiguangSigning"),
)).expanduser().resolve()
MANIFEST = SIGNING_HOME / "identity.json"
KEYCHAIN = SIGNING_HOME / "signing.keychain-db"
PASSWORD = SIGNING_HOME / "keychain-password"
CERTIFICATE = SIGNING_HOME / "certificate.der"


class SigningError(Exception):
    pass


def run(arguments, **kwargs):
    result = subprocess.run(arguments, capture_output=True, text=True, **kwargs)
    if result.returncode:
        # Some commands contain a generated keychain password; never echo argv.
        detail = (result.stderr or result.stdout).strip()
        if PASSWORD.exists():
            detail = detail.replace(PASSWORD.read_text().strip(), "<redacted>")
        raise SigningError(f"{Path(arguments[0]).name} failed: {detail}")
    return result.stdout


def requirement(fingerprint):
    return f'identifier "{IDENTIFIER}" and certificate leaf = H"{fingerprint}"'


def read_identity():
    if not MANIFEST.is_file():
        raise SigningError("No persistent signing identity. Run: python3 scripts/local-signing.py init")
    identity = json.loads(MANIFEST.read_text())
    fingerprint = identity.get("certificate_sha1", "")
    if (identity.get("identifier") != IDENTIFIER
            or not re.fullmatch(r"[0-9A-F]{40}", fingerprint)):
        raise SigningError("Invalid signing identity manifest; refusing to replace the identity.")
    for path in (CERTIFICATE, KEYCHAIN, PASSWORD):
        if not path.is_file() or path.is_symlink():
            raise SigningError(f"Signing material missing or invalid: {path}. Restore it from backup.")
    actual = hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest().upper()
    if actual != fingerprint:
        raise SigningError("Signing certificate changed; refusing an update with a different identity.")
    if SIGNING_HOME.stat().st_mode & 0o077 or PASSWORD.stat().st_mode & 0o077:
        raise SigningError("Signing directory must be private (0700), and password file must be 0600.")
    return identity


def sign_with_identity(app, fingerprint):
    run([
        "/usr/bin/codesign", "--force", "--sign", fingerprint,
        "--keychain", str(KEYCHAIN), "--timestamp=none",
        "--identifier", IDENTIFIER,
        "--requirements", "=designated => " + requirement(fingerprint),
        str(app),
    ])
    run(["/usr/bin/codesign", "--verify", "--strict",
         "-R=" + requirement(fingerprint), str(app)])
    details = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
        capture_output=True, text=True, check=True,
    ).stderr
    if "Signature=adhoc" in details:
        raise SigningError("Ad hoc signature is not allowed for the installed app.")


def check():
    identity = read_identity()
    print(f"Persistent signing identity: {identity['certificate_sha1']}")
    return identity


def sign(app):
    identity = read_identity()
    app = app.resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise SigningError("Expected an existing .app bundle.")
    run(["/usr/bin/security", "unlock-keychain", "-p", PASSWORD.read_text().strip(), str(KEYCHAIN)])
    try:
        sign_with_identity(app, identity["certificate_sha1"])
    finally:
        run(["/usr/bin/security", "lock-keychain", str(KEYCHAIN)])
    print(f"Signed with persistent identity: {app}")


def finish_initialize(directory):
    fingerprint = hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest().upper()
    run(["/usr/bin/security", "unlock-keychain", "-p", PASSWORD.read_text().strip(), str(KEYCHAIN)])
    try:
        probe = directory / "signing-probe"
        # Do not copy the protected system binary's filesystem flags.
        shutil.copyfile("/usr/bin/true", probe)
        probe.chmod(0o700)
        sign_with_identity(probe, fingerprint)
        MANIFEST.write_text(json.dumps({
            "identifier": IDENTIFIER,
            "certificate_sha1": fingerprint,
            "designated_requirement": requirement(fingerprint),
        }, indent=2) + "\n")
        MANIFEST.chmod(0o600)
    finally:
        run(["/usr/bin/security", "lock-keychain", str(KEYCHAIN)])
    print(f"Created persistent local signing identity: {fingerprint}")
    print(f"Keep this directory private and backed up: {SIGNING_HOME}")


def initialize():
    if MANIFEST.exists():
        check()
        print("Reusing existing identity; no certificate was created.")
        return
    if SIGNING_HOME.exists() and any(SIGNING_HOME.iterdir()):
        if all(path.is_file() for path in (CERTIFICATE, KEYCHAIN, PASSWORD)):
            with tempfile.TemporaryDirectory(prefix=".setup-", dir=SIGNING_HOME) as temporary:
                finish_initialize(Path(temporary))
            return
        raise SigningError(f"Incomplete identity at {SIGNING_HOME}; refusing to generate a replacement.")
    SIGNING_HOME.mkdir(parents=True, mode=0o700, exist_ok=True)
    SIGNING_HOME.chmod(0o700)
    secret = secrets.token_hex(32)
    PASSWORD.write_text(secret + "\n")
    PASSWORD.chmod(0o600)

    with tempfile.TemporaryDirectory(prefix=".setup-", dir=SIGNING_HOME) as temporary:
        directory = Path(temporary)
        config = directory / "certificate.cnf"
        config.write_text(
            "[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=extensions\n"
            "[subject]\nCN=Shiguang Local Code Signing\n"
            "[extensions]\nbasicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n"
            "subjectKeyIdentifier=hash\n"
        )
        key, certificate, archive = (directory / name for name in ("key.pem", "certificate.pem", "identity.p12"))
        run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes",
             "-x509", "-sha256", "-days", "3650", "-config", str(config),
             "-keyout", str(key), "-out", str(certificate)])
        run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER", "-out", str(CERTIFICATE)])
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key),
             "-in", str(certificate), "-out", str(archive),
             "-passout", "file:" + str(PASSWORD)])
        run(["/usr/bin/security", "create-keychain", "-p", secret, str(KEYCHAIN)])
        # The dedicated keychain is addressed explicitly; keep it out of normal searches.
        search_list = run(["/usr/bin/security", "list-keychains", "-d", "user"])
        paths = re.findall(r'^\s*"(.+)"\s*$', search_list, flags=re.MULTILINE)
        if str(KEYCHAIN) in paths:
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s",
                 *[path for path in paths if path != str(KEYCHAIN)]])
        run(["/usr/bin/security", "set-keychain-settings", "-lut", "300", str(KEYCHAIN)])
        try:
            run(["/usr/bin/security", "import", str(archive), "-k", str(KEYCHAIN),
                 "-P", secret, "-T", "/usr/bin/codesign"])
            finish_initialize(directory)
        finally:
            run(["/usr/bin/security", "lock-keychain", str(KEYCHAIN)])


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["init", "check", "sign"])
    parser.add_argument("app", nargs="?", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.action == "init":
            initialize()
        elif arguments.action == "check":
            check()
        elif arguments.app is not None:
            sign(arguments.app)
        else:
            parser.error("sign requires an app path")
    except (SigningError, OSError, ValueError, subprocess.SubprocessError) as error:
        if isinstance(error, subprocess.SubprocessError):
            print("Signing failed while verifying the signature.", file=sys.stderr)
        else:
            print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
