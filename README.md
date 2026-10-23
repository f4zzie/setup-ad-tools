# AD Tools Setup

A Bash installer for Active Directory assessment tools on Linux.
Use the installed tools only in environments where you have permission to test.
The installer performs local startup checks; it does not test AD targets or execute
the downloaded Windows binaries.

## Compatibility

- **Tested:** Arch Linux on x86_64, including actual installation, local startup checks,
  shell PATH configuration, and downloaded artifact checks.
- **Implemented but untested:** Debian/Ubuntu/Kali and Fedora/RHEL/Rocky/Alma package paths.
  Availability of packages and required repositories can differ between distributions.
- **Untested:** Arch derivatives and ARM architectures. Architecture detection does not
  guarantee that each upstream project publishes a compatible binary.
- **Unsupported:** macOS, FreeBSD, and other non-Linux Unix systems.

This is not an installer tested across all Unix distributions.
The installation was tested on an existing Arch system, not a clean-install distro matrix.
The Python tool environments used CPython 3.12. Compatibility of every upstream tool with
newer Python versions has not been established.

## Usage

Keep `setup-ad-tools.sh` and `setup-ad-tools-assets.py` in the same directory.
Run as a regular user with access to `sudo`, not as root.

```bash
git clone https://github.com/f4zzie/setup-ad-tools.git
cd setup-ad-tools
./setup-ad-tools.sh --help
./setup-ad-tools.sh
```

Review the script first. System installation changes installed packages.
**On Arch, the system phase runs a full upgrade with `pacman -Syu`.**
The default destination is `~/Desktop/AD`; the script never deletes that directory.

Skip the initial confirmation:

```bash
./setup-ad-tools.sh --yes
```

Rerun without changing system packages:

```bash
./setup-ad-tools.sh --yes --skip-system
```

Select one phase, for example to retry PowerShell downloads:

```bash
./setup-ad-tools.sh --yes --skip-system --phase=powershell
```

Available phases: `all`, `system`, `python`, `ruby`, `standalone`, `repos`, `windows`,
`powershell`, and `verify`. The `verify` phase checks command availability, not AD behavior.
All phases still require the runtime prerequisites and write logs and PATH configuration.

Set `AD_DIR` to choose another destination. Set `AD_PYTHON` to the path of an installed
Python interpreter with working `venv` support:

```bash
AD_DIR="$HOME/AD" AD_PYTHON=/path/to/python3.12 ./setup-ad-tools.sh --yes
```

The installer does not install an alternate Python version automatically.
`--yes` skips the installer confirmation, not sudo authentication.
Do not put passwords in the script, configuration, or repository.

## Installed Content

- System tools such as Samba clients, Hashcat, John, and ProxyChains.
- Isolated Python applications including NetExec, Impacket, BloodHound's Python collector,
  Certipy, Coercer, and others listed in the installer.
- Evil-WinRM through a user-scoped Ruby installation.
- Kerbrute, Chisel, and Ligolo proxy.
- Source checkouts and isolated environments for repository-based tools.
- Windows binaries under `$AD_DIR/bin`, preserving collection build variants.
- PowerShell files under `$AD_DIR/scripts`.

CrackMapExec is intentionally skipped in favor of maintained NetExec (`nxc`).
SweetPotato source is retained, with compiled variants in SharpCollection.
The BloodHound server and Neo4j services are not deployed by this installer.

Python command-line applications use pipx; repository-based Python tools use local virtual
environments. Existing environments and checkouts are retained on reruns, but requirements
installation can still change dependencies. This is not a fully locked or reproducible build.

The installer configures PATH through `~/.config/ad-tools/path.sh` and adds a source line
to Bash, Zsh, and profile configuration, backing up existing files before appending.
Open a new terminal or activate it immediately:

```bash
. "$HOME/.config/ad-tools/path.sh"
```

## Downloads And Logs

Downloads use HTTPS. Published release hashes are checked when available; otherwise a
local hash is recorded without claiming upstream authenticity. GitHub API failures fall
back to explicit release filenames, and raw GitHub downloads resolve a branch to a commit.
Third-party compiled collections are not independently audited or authenticated by this project.

Temporary downloads use a private directory. File replacement is atomic after download
validation. Archive extraction rejects traversal and links, and tar extraction rejects
special files. These checks do not establish that upstream code or binaries are safe.

Each run writes `$AD_DIR/logs/<timestamp>-<pid>/` containing:

- `results.tsv`: task outcomes and log paths.
- `sources.tsv`: source URLs, hashes, and checkout commits.
- `artifacts.sha256`: hashes of final Windows and PowerShell artifacts.
- `pipx-final.json`: installed pipx inventory.
- Per-task diagnostic logs.

Individual tool failures are reported while other tasks continue. Unresolved task failures
produce a nonzero final exit status; prerequisite or system package failures can stop the run.
Installation logs and downloaded tools are intentionally excluded from this repository.

## Tests

Run the offline tests and shell lint without installing assessment tools:

```bash
python3 test-setup-ad-tools.py
shellcheck setup-ad-tools.sh
```

The suite contains 15 regression tests covering shell syntax, help behavior, task failures,
download preservation, API fallback, archive handling, script validation, and launchers.
It needs Python 3, Bash, and standard Linux command-line utilities.
The encrypted ZIP test uses `zip` and is skipped when it is unavailable.
ShellCheck is a separate dependency.

Passing these tests does not establish cross-distribution compatibility or live AD functionality.
Downloaded third-party projects retain their respective licenses and usage terms.
