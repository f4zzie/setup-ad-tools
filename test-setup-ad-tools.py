#!/usr/bin/env python3
"""Offline regression tests; does not install tools or contact targets."""

import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("assets", ROOT / "setup-ad-tools-assets.py")
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class InstallerTests(unittest.TestCase):
    def test_syntax(self):
        subprocess.run(["bash", "-n", ROOT / "setup-ad-tools.sh"], check=True)

    def test_help_is_side_effect_free(self):
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run(
                ["bash", ROOT / "setup-ad-tools.sh", "--help"],
                env={**os.environ, "HOME": home},
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(list(Path(home).iterdir()), [])

    def test_script_allows_embedded_html(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "tool.ps1"
            script.write_text("function Invoke-Tool {\n$html = '<html>hello</html>'\n}\n")
            assets.validate_script(script)

    def test_script_rejects_html_document(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "tool.ps1"
            script.write_text("\ufeff \n<!DOCTYPE html><html>Error</html>")
            with self.assertRaises(ValueError):
                assets.validate_script(script)

    def test_runner_stops_failed_function_and_continues_next_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''
source "$INSTALLER"
LOG_DIR="$TEST_DIR"
RESULTS="$TEST_DIR/results"
bad_install() {
    false
    touch "$TEST_DIR/false-success"
}
attempt broken bad_install
attempt good true
[[ "$FAILED" == 1 && "$SUCCEEDED" == 1 ]]
[[ ! -e "$TEST_DIR/false-success" ]]
'''
            subprocess.run(
                ["bash", "-c", script],
                env={
                    **os.environ,
                    "INSTALLER": str(ROOT / "setup-ad-tools.sh"),
                    "TEST_DIR": directory,
                },
                check=True,
                capture_output=True,
            )

    def test_failed_download_preserves_existing_file(self):
        self.check_download_failure(
            'curl() { printf partial > "${@: -1}"; return 22; }', ""
        )

    def test_checksum_mismatch_preserves_existing_file(self):
        self.check_download_failure(
            'curl() { printf replacement > "${@: -1}"; }', "0" * 64
        )

    def test_api_failure_uses_exact_release_and_stops_retrying_api(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''
source "$INSTALLER"
LOG_DIR="$TEST_DIR"
WORK_DIR="$TEST_DIR"
fetch() {
    printf '%s\n' "$1" >> "$TEST_DIR/requests"
    [[ "$1" != https://api.github.com/* ]] || return 22
    printf MZ > "$2"
}
release_asset owner/project v1 '^tool\.exe$' tool.exe
[[ -s "$ASSET" ]]
release_asset owner/other v2 '^other\.exe$' other.exe
[[ -s "$ASSET" ]]
'''
            subprocess.run(
                ["bash", "-c", script],
                env={
                    **os.environ,
                    "INSTALLER": str(ROOT / "setup-ad-tools.sh"),
                    "TEST_DIR": directory,
                },
                check=True,
                capture_output=True,
            )
            requests = (Path(directory) / "requests").read_text().splitlines()
            self.assertEqual(requests, [
                "https://api.github.com/repos/owner/project/releases/tags/v1",
                "https://github.com/owner/project/releases/download/v1/tool.exe",
                "https://github.com/owner/other/releases/download/v2/other.exe",
            ])

    def test_download_accepts_form_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            script = r'''
source "$INSTALLER"
MANIFEST="$TEST_DIR/manifest"
curl() {
    printf '%s\n' "$@" > "$TEST_DIR/arguments"
    printf archive > "${@: -1}"
}
fetch https://example.invalid/download "$TEST_DIR/download" "" \
    --data-urlencode 'download=AdFind.zip'
'''
            subprocess.run(
                ["bash", "-c", script],
                env={
                    **os.environ,
                    "INSTALLER": str(ROOT / "setup-ad-tools.sh"),
                    "TEST_DIR": directory,
                },
                check=True,
                capture_output=True,
            )
            arguments = (Path(directory) / "arguments").read_text().splitlines()
            index = arguments.index("--data-urlencode")
            self.assertEqual(arguments[index + 1], "download=AdFind.zip")

    def check_download_failure(self, curl_function, digest):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "existing"
            destination.write_text("original")
            script = r'''
source "$INSTALLER"
MANIFEST="$TEST_DIR/manifest"
''' + curl_function + r'''
if fetch https://example.invalid/file "$TEST_DIR/existing" "$EXPECTED_HASH"; then
    exit 1
fi
'''
            subprocess.run(
                ["bash", "-c", script],
                env={
                    **os.environ,
                    "INSTALLER": str(ROOT / "setup-ad-tools.sh"),
                    "TEST_DIR": directory,
                    "EXPECTED_HASH": digest,
                },
                check=True,
                capture_output=True,
            )
            self.assertEqual(destination.read_text(), "original")
            self.assertEqual(list(root.glob("*.part.*")), [])

    def test_zip_traversal_rejected_before_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "bad.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("good", "good")
                bundle.writestr("../outside", "bad")
            with self.assertRaises(ValueError):
                assets.extract(archive, root / "output")
            self.assertFalse((root / "outside").exists())
            self.assertFalse((root / "output/good").exists())

    def test_tar_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                item = tarfile.TarInfo("link")
                item.type = tarfile.SYMTYPE
                item.linkname = "/tmp"
                bundle.addfile(item)
            with self.assertRaises(ValueError):
                assets.extract(archive, root / "output")

    @unittest.skipUnless(shutil.which("zip"), "zip command not installed")
    def test_zip_with_bundled_password_extracts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tool.exe").write_bytes(b"MZfixture")
            (root / "password.txt").write_text("fixture-password\n")
            archive = root / "encrypted.zip"
            subprocess.run(
                ["zip", "-q", "-P", "fixture-password", str(archive), "tool.exe"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                ["zip", "-q", str(archive), "password.txt"], cwd=root, check=True
            )
            assets.extract(archive, root / "output", "password.txt")
            self.assertEqual((root / "output/tool.exe").read_bytes(), b"MZfixture")

    def test_regular_tar_extracts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "good.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                item = tarfile.TarInfo("nested/proxy")
                item.size = 3
                bundle.addfile(item, io.BytesIO(b"ELF"))
            assets.extract(archive, root / "output")
            self.assertEqual((root / "output/nested/proxy").read_bytes(), b"ELF")

    def test_launcher_does_not_replace_existing_command(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "command"
            target.write_text("existing")
            with self.assertRaises(FileExistsError):
                assets.launcher(directory, "main.py", target)
            self.assertEqual(target.read_text(), "existing")

    def test_launcher_handles_spaces(self):
        with tempfile.TemporaryDirectory(prefix="AD tools ") as directory:
            target = Path(directory) / "command"
            assets.launcher(directory, "main.py", target)
            subprocess.run(["bash", "-n", target], check=True)
            self.assertTrue(os.access(target, os.X_OK))


if __name__ == "__main__":
    unittest.main()
