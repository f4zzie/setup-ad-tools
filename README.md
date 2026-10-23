# AD Tools Setup

Set up common Active Directory (AD) assessment tools on a Linux workstation.
This installer handles system packages, separate Python environments, command shortcuts,
and downloads of Windows tools and PowerShell scripts.

It is a setup script, not an automated attack or vulnerability scanner.
It does not ask for domain credentials, test AD targets, or execute the Windows binaries.
Use the installed tools only in environments where you have permission to test.

**Tested on Arch Linux x86_64. Other Linux distribution support is not yet verified.**

## Before You Run

- Review the installer before running it. It downloads and installs third-party software.
- Use a regular user account with `sudo` access. Do not run the whole script as root.
- You need an internet connection and available disk space for packages and tool collections.
- **On Arch, installation includes a full system upgrade with `pacman -Syu`.**
- The default tool folder is `~/Desktop/AD`. Existing contents are not deleted.
- The installer also changes shell PATH configuration and installs tools outside that folder.

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

## Quick Start

Keep `setup-ad-tools.sh` and `setup-ad-tools-assets.py` in the same directory.

1. Download the repository and view the available options:

```bash
git clone https://github.com/f4zzie/setup-ad-tools.git
cd setup-ad-tools
./setup-ad-tools.sh --help
```

2. Review the script, then start installation:

```bash
./setup-ad-tools.sh
```

The script asks for confirmation before starting. Enter your sudo password only at the
local sudo prompt, never in a source file or GitHub issue.

3. When installation finishes, open a new terminal or load the updated command paths:

```bash
. "$HOME/.config/ad-tools/path.sh"
```

Linux command-line tools are then available from the terminal. Downloaded Windows executables
remain files for use on Windows; downloading them does not make them Linux applications.

## Options

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

## Understanding Results

- **`OK`:** that installation or verification step completed successfully.
  Some checks only confirm that a command exists; others run its help command.
  Neither proves that the tool will work against a live AD environment.
- **`FAIL`:** the step failed. The output shows its diagnostic log path.
  Other tool steps continue, but the final exit status is nonzero.
- **`SKIP`:** an intentional omission, such as using NetExec instead of CrackMapExec.
  A skipped step is not counted as an installation failure.

If a download or dependency installation fails, read that step's log first. Once the cause
is resolved, rerun the relevant phase with `--skip-system` to avoid another system upgrade.
Prerequisite or system package failures can stop the run before other phases start.

### Log Files

Each run prints its log directory: `$AD_DIR/logs/<timestamp>-<pid>/`.

- `results.tsv`: task outcomes and log paths.
- `sources.tsv`: source URLs, hashes, and checkout commits.
- `artifacts.sha256`: hashes of final Windows and PowerShell artifacts.
- `pipx-final.json`: installed pipx inventory.
- Per-task diagnostic logs.

Installation logs and downloaded tools are intentionally excluded from this repository.
Before sharing your own logs, review them for private paths, credentials, or other sensitive data.

## Download Safety

Downloads use HTTPS. Published release hashes are checked when available; otherwise a
local hash is recorded without claiming upstream authenticity. GitHub API failures fall
back to explicit release filenames, and raw GitHub downloads resolve a branch to a commit.
Third-party compiled collections are not independently audited or authenticated by this project.

Temporary downloads use a private directory. File replacement is atomic after download
validation. Archive extraction rejects traversal and links, and tar extraction rejects
special files. These checks do not establish that upstream code or binaries are safe.

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
