#!/usr/bin/env python3
"""Safe archive extraction and shell launchers for setup-ad-tools.sh."""

import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import sys
import tarfile
import tempfile
import zipfile


def validate_script(path):
    text = Path(path).read_text(encoding="utf-8-sig")
    if not text.strip() or "\0" in text:
        raise ValueError("Expected a nonempty text script")
    # HTML strings inside a script are valid; an HTML document itself is not.
    if re.match(r"\s*<(?:!doctype\s+html\b|html\b)", text, re.IGNORECASE):
        raise ValueError("Downloaded an HTML document instead of a script")


def member_path(name):
    path = PurePosixPath(name.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or ":" in name:
        raise ValueError(f"Unsafe archive member: {name!r}")
    return path


def extract(archive, destination, password_member=None):
    root = Path(destination)
    root.mkdir(parents=True, exist_ok=False)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as bundle:
            members = bundle.infolist()
            for item in members:
                member_path(item.filename)
                if stat.S_ISLNK(item.external_attr >> 16):
                    raise ValueError(f"Archive symlink: {item.filename!r}")
            password = None
            if password_member is not None and any(item.flag_bits & 1 for item in members):
                item = bundle.getinfo(password_member)
                if item.flag_bits & 1 or item.file_size > 1024:
                    raise ValueError("Expected a small, unencrypted archive password file")
                password = bundle.read(item).strip()
            for item in members:
                target = root / member_path(item.filename)
                if item.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(item, pwd=password) as src, target.open("xb") as dst:
                        shutil.copyfileobj(src, dst)
    else:
        with tarfile.open(archive) as bundle:
            members = bundle.getmembers()
            for item in members:
                member_path(item.name)
                if not (item.isfile() or item.isdir()):
                    raise ValueError(f"Unsupported archive member: {item.name!r}")
            for item in members:
                target = root / member_path(item.name)
                if item.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.extractfile(item) as src, target.open("xb") as dst:
                        shutil.copyfileobj(src, dst)


def atomic_text(destination, text, mode):
    target = Path(destination)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".ad-tools-", dir=target.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def launcher(directory, entry, destination):
    root = Path(directory).resolve()
    target = Path(destination)
    text = (
        "#!/usr/bin/env bash\n"
        "# Managed by setup-ad-tools.sh\n"
        "set -euo pipefail\n"
        f"cd -- {shlex.quote(str(root))}\n"
        f"exec {shlex.quote(str(root / '.venv/bin/python'))} "
        f"{shlex.quote(str(root / entry))} \"$@\"\n"
    )
    if target.exists() or target.is_symlink():
        if target.is_symlink() or "Managed by setup-ad-tools.sh" not in target.read_text():
            raise FileExistsError(f"Refusing to overwrite existing command: {target}")
    atomic_text(target, text, 0o755)


def shell_path(gem_bin):
    atomic_text(
        Path.home() / ".config/ad-tools/path.sh",
        "# Managed by setup-ad-tools.sh\n"
        'case ":$PATH:" in\n'
        '    *":$HOME/.local/bin:"*) ;;\n'
        '    *) export PATH="$HOME/.local/bin:$PATH" ;;\n'
        "esac\n"
        f"case \":$PATH:\" in\n"
        f"    *{shlex.quote(':' + gem_bin + ':')}*) ;;\n"
        f"    *) export PATH={shlex.quote(gem_bin)}:\"$PATH\" ;;\n"
        "esac\n",
        0o644,
    )


if __name__ == "__main__":
    action, *arguments = sys.argv[1:]
    actions = {
        "extract": extract,
        "launcher": launcher,
        "path": shell_path,
        "script": validate_script,
    }
    actions[action](*arguments)
