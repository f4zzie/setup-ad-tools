#!/usr/bin/env bash
# AD tools installer. No target testing or services are started.
set -euo pipefail

ASSUME_YES=0
SKIP_SYSTEM=0
PHASE=all
AD_DIR="${AD_DIR:-${HOME}/Desktop/AD}"
LOCAL_BIN="${HOME}/.local/bin"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
SUCCEEDED=0
SKIPPED=0

usage() {
    printf '%s\n' \
        "Usage: $0 [-y|--yes] [--skip-system] [--phase=NAME]" \
        "Phases: all, system, python, ruby, standalone, repos, windows, powershell, verify" \
        "AD_DIR overrides the destination; AD_PYTHON selects the Python interpreter." \
        "Existing installations are retained. This script never deletes the AD directory." \
        "Arch system installation includes a full system upgrade."
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) ASSUME_YES=1 ;;
            --skip-system) SKIP_SYSTEM=1 ;;
            --phase=*) PHASE="${arg#*=}" ;;
            -h|--help) usage; exit 0 ;;
            *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
        esac
    done
    case "$PHASE" in
        all|system|python|ruby|standalone|repos|windows|powershell|verify) ;;
        *) printf 'Unknown phase: %s\n' "$PHASE" >&2; exit 2 ;;
    esac
}

info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

detect_system() {
    # shellcheck source=/dev/null
    source /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *debian*|*ubuntu*) FAMILY=debian ;;
        *arch*|*manjaro*) FAMILY=arch ;;
        *fedora*|*rhel*|*centos*|*rocky*|*alma*) FAMILY=fedora ;;
        *) warn "Unsupported distribution: ${ID:-unknown}"; return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        armv7l) ARCH=armv7 ;;
        *) warn "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
}

record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"
    info "$1: $2 ($3)"
}

attempt() {
    local name="$1" rc logfile
    shift
    logfile="${LOG_DIR}/${name}.log"
    info "Starting $name"
    # Do not put the subshell in an if/|| list: that disables errexit in functions.
    set +e
    ( set -e; "$@" ) > "$logfile" 2>&1
    rc=$?
    set -e
    if (( rc == 0 )); then
        SUCCEEDED=$((SUCCEEDED + 1))
        record OK "$name" "$logfile"
    else
        FAILED=$((FAILED + 1))
        record FAIL "$name" "$logfile"
        tail -n 5 "$logfile" >&2
    fi
    return 0
}

skip() {
    SKIPPED=$((SKIPPED + 1))
    record SKIP "$1" "$2"
}

cleanup() {
    [[ -z "${WORK_DIR:-}" ]] || rm -rf -- "$WORK_DIR"
}

fetch() {
    local url="$1" dest="$2" expected="${3:-}" stage actual
    local -a options=("${@:4}")
    mkdir -p -- "$(dirname -- "$dest")"
    stage="$(mktemp "${dest}.part.XXXXXX")"
    if ! curl --proto '=https' --proto-redir '=https' -fLsS \
        --connect-timeout 20 --max-time 600 --retry 2 \
        "${options[@]}" "$url" -o "$stage"; then
        rm -f -- "$stage"
        return 1
    fi
    if [[ ! -s "$stage" ]]; then
        rm -f -- "$stage"
        return 1
    fi
    actual="$(sha256sum "$stage")"
    actual="${actual%% *}"
    if [[ -n "$expected" && "$actual" != "${expected#sha256:}" ]]; then
        warn "Checksum mismatch: $url"
        rm -f -- "$stage"
        return 1
    fi
    mv -fT -- "$stage" "$dest"
    printf '%s\t%s\t%s\t%s\n' "$actual" "${expected:-unverified}" "$url" "$dest" \
        >> "$MANIFEST"
}

release_asset() {
    local repo="$1" tag="$2" pattern="$3" fallback="${4:-}"
    local json asset url digest filename
    json="${LOG_DIR}/${repo//\//_}-${tag}.json"
    if [[ ! -s "$json" ]]; then
        if [[ "$tag" == latest ]]; then
            url="https://api.github.com/repos/${repo}/releases/latest"
        else
            url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
        fi
        if [[ -f "${WORK_DIR}/api-unavailable" ]] || ! fetch "$url" "$json"; then
            touch "${WORK_DIR}/api-unavailable"
            release_without_api "$repo" "$tag" "$fallback"
            return
        fi
    fi
    asset="$(jq -ce --arg re "$pattern" \
        '[.assets[] | select(.name | test($re; "i"))] |
         if length == 1 then .[0] else error("Expected exactly one release asset") end' \
        "$json")"
    filename="$(jq -r '.name' <<< "$asset")"
    [[ "$filename" != */* && "$filename" != .* ]]
    url="$(jq -r '.browser_download_url' <<< "$asset")"
    digest="$(jq -r '.digest // empty' <<< "$asset")"
    ASSET="${WORK_DIR}/${repo//\//_}-${filename}"
    if [[ -z "$digest" ]]; then
        warn "No upstream SHA-256 for $filename; recording the downloaded hash only."
    fi
    fetch "$url" "$ASSET" "$digest"
}

release_without_api() {
    local repo="$1" tag="$2" filename="$3" url digest="" checksums
    [[ -n "$filename" && "$filename" != */* && "$filename" != .* ]]
    warn "API unavailable; using the explicit release filename: $filename"
    if [[ "$tag" == latest ]]; then
        url="$(curl --proto '=https' --proto-redir '=https' -fLsS \
            --connect-timeout 20 --max-time 90 -o /dev/null -w '%{url_effective}' \
            "https://github.com/${repo}/releases/latest")"
        [[ "$url" == "https://github.com/${repo}/releases/tag/"* ]]
        tag="${url##*/}"
    fi
    url="https://github.com/${repo}/releases/download/${tag}"
    case "$repo" in
        jpillora/chisel|nicocha30/ligolo-ng)
            checksums="${WORK_DIR}/${repo//\//_}-checksums.txt"
            fetch "${url}/${repo##*/}_${tag#v}_checksums.txt" "$checksums"
            digest="$(awk -v name="$filename" '$2 == name {print $1}' "$checksums")"
            [[ "$digest" =~ ^[0-9a-f]{64}$ ]]
            ;;
        Kevin-Robertson/Inveigh)
            if [[ "$filename" == Inveigh-net10.0-win-x64-nativeaot-v2.0.12.zip ]]; then
                digest="12124cfe737b4247eaf4001804af99ca41c886251da8eaf1ff2c56d823d73f73"
            fi
            ;;
    esac
    ASSET="${WORK_DIR}/${repo//\//_}-${filename}"
    [[ -n "$digest" ]] || warn "No upstream checksum available; hash is a record, not verification."
    fetch "${url}/${filename}" "$ASSET" "$digest"
}

publish() {
    local src="$1" dest="$2" mode="${3:-644}" stage
    [[ -s "$src" && ! -L "$src" ]]
    mkdir -p -- "$(dirname -- "$dest")"
    stage="$(mktemp "$(dirname -- "$dest")/.ad-install.XXXXXX")"
    install -m "$mode" -- "$src" "$stage"
    mv -fT -- "$stage" "$dest"
}

extract_archive() {
    "$PYTHON" "$SCRIPT_DIR/setup-ad-tools-assets.py" extract "$@"
}

require_pe() {
    [[ "$(LC_ALL=C head -c 2 -- "$1")" == MZ ]]
}

install_system() {
    local -a packages optional
    case "$FAMILY" in
        arch)
            packages=(git curl wget unzip jq xz ca-certificates base-devel python python-pip
                python-pipx go ruby ruby-erb libldap smbclient hashcat john proxychains-ng
                shellcheck)
            sudo pacman -Syu --needed --noconfirm "${packages[@]}"
            ;;
        debian)
            packages=(git curl wget unzip jq xz-utils ca-certificates build-essential
                python3 python3-pip python3-venv python3-dev pipx golang-go ruby ruby-dev
                libldap2-dev libsasl2-dev libssl-dev libffi-dev samba-common-bin smbclient)
            sudo apt-get update
            sudo apt-get install -y "${packages[@]}"
            optional=(hashcat john proxychains4 shellcheck)
            for package in "${optional[@]}"; do
                attempt "system-${package}" sudo apt-get install -y "$package"
            done
            ;;
        fedora)
            packages=(git curl wget unzip jq xz ca-certificates gcc gcc-c++ make
                python3 python3-pip python3-devel pipx golang ruby ruby-devel
                openldap-devel cyrus-sasl-devel openssl-devel libffi-devel
                samba-client samba-common-tools)
            sudo dnf install -y "${packages[@]}"
            optional=(hashcat john proxychains-ng ShellCheck)
            for package in "${optional[@]}"; do
                attempt "system-${package}" sudo dnf install -y "$package"
            done
            ;;
    esac
}

verify_runtimes() {
    local cmd
    for cmd in git curl jq gcc make pipx go ruby gem sha256sum timeout; do
        command -v "$cmd" || return 1
    done
    "$PYTHON" -m venv "${WORK_DIR}/venv-check" || return 1
    "${WORK_DIR}/venv-check/bin/python" -m pip --version
}

pipx_tool() {
    local name="$1" spec="$2" app="$3"
    if pipx list --json | jq -e --arg name "$name" '.venvs[$name] != null' >/dev/null; then
        info "Keeping existing pipx environment: $name"
    else
        timeout 900 pipx install --python "$PYTHON" "$spec"
    fi
    if [[ "$name" == aclpwn ]]; then
        # ACLPwn 1.0 imports neo4j.v1, which was removed from newer drivers.
        timeout 900 pipx inject --force aclpwn 'neo4j-driver==1.7.6' 'setuptools<81'
    fi
    command -v "$app"
    timeout 45 "$app" --help
}

install_python() {
    local name spec app
    while IFS='|' read -r name spec app; do
        attempt "$name" pipx_tool "$name" "$spec" "$app"
    done <<'TOOLS'
netexec|git+https://github.com/Pennyw0rth/NetExec.git|nxc
impacket|impacket|secretsdump.py
bloodhound|bloodhound|bloodhound-python
bloodhound-import|bloodhound-import|bloodhound-import
certipy-ad|certipy-ad|certipy
coercer|coercer|coercer
mitm6|mitm6|mitm6
ldapdomaindump|ldapdomaindump|ldapdomaindump
pywerview|pywerview|pywerview
ldeep|ldeep|ldeep
donpapi|donpapi|donpapi
aclpwn|aclpwn|aclpwn
smbmap|smbmap|smbmap
adexplorersnapshot|git+https://github.com/c3c/ADExplorerSnapshot.py.git|ADExplorerSnapshot.py
TOOLS
    skip crackmapexec "Legacy project; maintained replacement NetExec is installed as nxc."
}

install_ruby() {
    local gem_bin
    gem_bin="$(ruby -rrubygems -e 'print Gem.user_dir')/bin"
    if ! command -v evil-winrm >/dev/null; then
        timeout 900 gem install --user-install --no-document evil-winrm
    fi
    export PATH="${gem_bin}:$PATH"
    command -v evil-winrm
    timeout 45 evil-winrm --help
}

install_standalone() {
    local name="$1" repo="$2" tag="$3" pattern="$4" filename="$5" member="${6:-}"
    local output="${WORK_DIR}/${name}-extracted"
    if command -v "$name" >/dev/null; then
        timeout 30 "$name" --help
        return 0
    fi
    release_asset "$repo" "$tag" "$pattern" "$filename"
    case "$ASSET" in
        *.tar.gz)
            extract_archive "$ASSET" "$output"
            publish "${output}/${member}" "${LOCAL_BIN}/${name}" 755
            ;;
        *.gz)
            gzip -dc -- "$ASSET" > "$output"
            publish "$output" "${LOCAL_BIN}/${name}" 755
            ;;
        *) publish "$ASSET" "${LOCAL_BIN}/${name}" 755 ;;
    esac
    timeout 30 "${LOCAL_BIN}/${name}" --help
}

clone_repo() {
    local repo="$1" dest="$2" commit
    if [[ -e "$dest" || -L "$dest" ]]; then
        [[ -d "$dest/.git" ]] || { warn "Refusing to replace $dest"; return 1; }
        info "Keeping existing checkout: $dest"
    else
        local stage
        stage="$(mktemp -d "${WORK_DIR}/clone.XXXXXX")"
        timeout 900 git -c core.hooksPath=/dev/null clone --depth 1 \
            "https://github.com/${repo}.git" "${stage}/repo"
        mkdir -p -- "$(dirname -- "$dest")"
        mv -T -- "${stage}/repo" "$dest"
    fi
    commit="$(git -C "$dest" rev-parse HEAD)"
    printf '%s\tgit-commit\thttps://github.com/%s\t%s\n' "$commit" "$repo" "$dest" \
        >> "$MANIFEST"
}

repo_tool() {
    local repo="$1" name="$2" entry="${3:-}" app="${4:-}"
    local dest="${TOOLS_DIR}/${name}"
    clone_repo "$repo" "$dest"
    [[ -n "$entry" ]] || return 0
    [[ -f "$dest/$entry" ]]
    if [[ ! -x "${dest}/.venv/bin/python" ]]; then
        "$PYTHON" -m venv "${dest}/.venv"
    fi
    if [[ -f "$dest/requirements.txt" ]]; then
        timeout 900 "${dest}/.venv/bin/python" -m pip install -r "$dest/requirements.txt"
    fi
    timeout 45 "${dest}/.venv/bin/python" "$dest/$entry" --help
    "$PYTHON" "$SCRIPT_DIR/setup-ad-tools-assets.py" launcher \
        "$dest" "$entry" "${LOCAL_BIN}/${app}"
}

install_repos() {
    attempt Responder repo_tool lgandx/Responder Responder Responder.py responder
    attempt gMSADumper repo_tool micahvandeusen/gMSADumper gMSADumper \
        gMSADumper.py gMSADumper
    attempt ADRecon repo_tool sense-of-security/ADRecon ADRecon
    attempt PlumHound repo_tool PlumHound/PlumHound PlumHound PlumHound.py plumhound
    attempt windapsearch repo_tool ropnop/windapsearch windapsearch windapsearch.py windapsearch
    attempt targetedKerberoast repo_tool ShutdownRepo/targetedKerberoast \
        targetedKerberoast targetedKerberoast.py targetedKerberoast
    attempt pyGPOAbuse repo_tool Hackndo/pyGPOAbuse pyGPOAbuse pygpoabuse.py pygpoabuse
    attempt dnschef repo_tool iphelix/dnschef dnschef dnschef.py dnschef
    attempt enum4linux-ng repo_tool cddmp/enum4linux-ng enum4linux-ng \
        enum4linux-ng.py enum4linux-ng
}

collection() {
    local repo="$1" name="$2" dest="${BIN_DIR}/$2"
    clone_repo "$repo" "$dest"
    find "$dest" -type f -iname '*.exe' -print -quit | grep .
}

windows_release() {
    local name="$1" repo="$2" tag="$3" pattern="$4" filename="$5"
    local dest="${BIN_DIR}/${name}" exe
    release_asset "$repo" "$tag" "$pattern" "$filename"
    case "$ASSET" in
        *.zip|*.tar.gz)
            extract_archive "$ASSET" "${WORK_DIR}/${name}-unpacked"
            exe="$(find "${WORK_DIR}/${name}-unpacked" -type f -iname '*.exe' -print -quit)"
            [[ -n "$exe" ]]
            require_pe "$exe"
            mkdir -p -- "$dest"
            cp -a -- "${WORK_DIR}/${name}-unpacked/." "$dest/"
            ;;
        *)
            require_pe "$ASSET"
            publish "$ASSET" "${dest}.exe"
            ;;
    esac
}

raw_github() {
    local repo="$1" branch="$2" path="$3" dest="$4" commit refs stage
    refs="${LOG_DIR}/${repo//\//_}-commit.txt"
    if [[ ! -s "$refs" ]]; then
        timeout 90 git ls-remote "https://github.com/${repo}.git" \
            "refs/heads/${branch}" > "$refs"
    fi
    read -r commit _ < "$refs"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]]
    stage="$(mktemp "${WORK_DIR}/raw.XXXXXX")"
    fetch "https://raw.githubusercontent.com/${repo}/${commit}/${path}" "$stage"
    if [[ "$dest" == *.exe ]]; then
        require_pe "$stage"
    else
        "$PYTHON" "$SCRIPT_DIR/setup-ad-tools-assets.py" script "$stage"
    fi
    publish "$stage" "$dest"
}

download_zip() {
    local name="$1" url="$2" required="$3" dest="${BIN_DIR}/$1"
    local stage="${WORK_DIR}/${name}"
    fetch "$url" "${stage}.zip"
    extract_archive "${stage}.zip" "$stage"
    [[ -s "$stage/$required" ]]
    require_pe "$stage/$required"
    mkdir -p -- "$dest"
    cp -a -- "$stage/." "$dest/"
}

download_adfind() {
    local stage="${WORK_DIR}/AdFind" dest="${BIN_DIR}/AdFind"
    # The official form accepts an empty email; the ZIP supplies its own password.
    fetch 'https://www.joeware.net/downloads/dl2.php' "${stage}.zip" "" \
        --data-urlencode 'download=AdFind.zip'
    extract_archive "${stage}.zip" "$stage" password.txt
    require_pe "${stage}/AdFind.exe"
    mkdir -p -- "$dest"
    cp -a -- "$stage/." "$dest/"
}

verify_sweetpotato() {
    local file
    file="$(find "${BIN_DIR}/SharpCollection" -type f -iname SweetPotato.exe -print -quit)"
    [[ -n "$file" ]]
    require_pe "$file"
    info "Compiled variants retained under ${BIN_DIR}/SharpCollection."
}

install_windows() {
    attempt GhostPack collection r3motecontrol/Ghostpack-CompiledBinaries GhostPack
    attempt SharpCollection collection Flangvik/SharpCollection SharpCollection
    attempt PetitPotam raw_github topotam/PetitPotam main PetitPotam.exe \
        "${BIN_DIR}/PetitPotam.exe"
    attempt PrintSpoofer64 windows_release PrintSpoofer64 itm4n/PrintSpoofer v1.0 \
        '^PrintSpoofer64\.exe$' PrintSpoofer64.exe
    attempt GodPotato-NET4 windows_release GodPotato-NET4 BeichenDream/GodPotato V1.20 \
        '^GodPotato-NET4\.exe$' GodPotato-NET4.exe
    attempt JuicyPotato windows_release JuicyPotato ohpe/juicy-potato v0.1 \
        '^JuicyPotato\.exe$' JuicyPotato.exe
    attempt RoguePotato windows_release RoguePotato antonioCoco/RoguePotato 1.0 \
        '^RoguePotato\.zip$' RoguePotato.zip
    attempt RemotePotato0 windows_release RemotePotato0 antonioCoco/RemotePotato0 1.2 \
        '^RemotePotato0\.zip$' RemotePotato0.zip
    attempt SweetPotato-source clone_repo CCob/SweetPotato "${TOOLS_DIR}/SweetPotato"
    attempt SweetPotato-collection verify_sweetpotato
    attempt PsExec download_zip PSTools \
        https://download.sysinternals.com/files/PSTools.zip PsExec64.exe
    attempt mimikatz windows_release mimikatz gentilkiwi/mimikatz latest \
        '^mimikatz_trunk\.zip$' mimikatz_trunk.zip
    attempt LaZagne windows_release LaZagne AlessandroZ/LaZagne latest \
        '^LaZagne\.exe$' LaZagne.exe
    attempt AdFind download_adfind
    attempt Inveigh windows_release Inveigh Kevin-Robertson/Inveigh v2.0.12 \
        '^Inveigh-net10\.0-win-x64-nativeaot-v2\.0\.12\.zip$' \
        Inveigh-net10.0-win-x64-nativeaot-v2.0.12.zip
}

install_powershell() {
    attempt PowerView raw_github PowerShellMafia/PowerSploit master Recon/PowerView.ps1 \
        "${SCRIPTS_DIR}/PowerView.ps1"
    attempt PowerUp raw_github PowerShellMafia/PowerSploit master Privesc/PowerUp.ps1 \
        "${SCRIPTS_DIR}/PowerUp.ps1"
    attempt Inveigh-ps1 raw_github Kevin-Robertson/Inveigh master Inveigh.ps1 \
        "${SCRIPTS_DIR}/Inveigh.ps1"
    attempt DomainPasswordSpray raw_github dafthack/DomainPasswordSpray master \
        DomainPasswordSpray.ps1 "${SCRIPTS_DIR}/DomainPasswordSpray.ps1"
}

setup_path() {
    local gem_bin rc line
    gem_bin="$(ruby -rrubygems -e 'print Gem.user_dir')/bin"
    export PATH="${LOCAL_BIN}:${gem_bin}:$PATH"
    "$PYTHON" "$SCRIPT_DIR/setup-ad-tools-assets.py" path "$gem_bin"
    # shellcheck disable=SC2016
    line='[ ! -f "$HOME/.config/ad-tools/path.sh" ] || . "$HOME/.config/ad-tools/path.sh"'
    for rc in "${HOME}/.bashrc" "${ZDOTDIR:-$HOME}/.zshrc" "${HOME}/.profile"; do
        if ! grep -Fqx "$line" "$rc" 2>/dev/null; then
            [[ ! -f "$rc" ]] || cp -p -- "$rc" "${rc}.ad-tools.$(date +%s).bak"
            printf '\n%s\n' "$line" >> "$rc"
        fi
    done
}

verify_tools() {
    local app
    for app in nxc secretsdump.py bloodhound-python certipy coercer mitm6 ldapdomaindump \
        pywerview ldeep donpapi aclpwn dnschef enum4linux-ng smbmap evil-winrm kerbrute \
        chisel ligolo-proxy responder gMSADumper plumhound windapsearch \
        targetedKerberoast pygpoabuse hashcat john proxychains4 smbclient rpcclient; do
        attempt "verify-${app}" command -v "$app"
    done
}

selected() { [[ "$PHASE" == all || "$PHASE" == "$1" ]]; }

main() {
    parse_args "$@"
    if (( EUID == 0 )); then
        warn "Run as your normal user; privileged package operations use sudo."
        exit 2
    fi
    detect_system
    printf 'System: %s (%s)\nDestination: %s\nPhase: %s\n' \
        "$PRETTY_NAME" "$ARCH" "$AD_DIR" "$PHASE"
    printf '%s\n' \
        'Downloads include third-party compiled Windows tools, which are not executed.' \
        'Release digests are checked when published; hashes alone do not establish trust.'
    if selected system && (( ! SKIP_SYSTEM )); then
        info "System packages will be installed; Arch also performs a full system upgrade."
    fi
    if (( ! ASSUME_YES )); then
        local answer
        read -r -p 'Proceed? [y/N] ' answer || exit 0
        [[ "$answer" =~ ^[Yy]$ ]] || exit 0
    fi
    umask 077
    BIN_DIR="${AD_DIR}/bin"
    SCRIPTS_DIR="${AD_DIR}/scripts"
    TOOLS_DIR="${AD_DIR}/tools"
    LOG_DIR="${AD_DIR}/logs/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p -- "$BIN_DIR" "$SCRIPTS_DIR" "$TOOLS_DIR" "$LOG_DIR" "$LOCAL_BIN"
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ad-tools.XXXXXXXX")"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    RESULTS="${LOG_DIR}/results.tsv"
    MANIFEST="${LOG_DIR}/sources.tsv"
    printf 'status\titem\tdetail\n' > "$RESULTS"
    printf 'hash\texpected\tsource\tdestination\n' > "$MANIFEST"
    export PATH="${LOCAL_BIN}:$PATH"
    export GIT_TERMINAL_PROMPT=0 PIP_DISABLE_PIP_VERSION_CHECK=1
    export PIP_DEFAULT_TIMEOUT=60 UV_HTTP_TIMEOUT=60
    if selected system && (( ! SKIP_SYSTEM )); then
        sudo -v
        # Keep package-manager output visible, especially dependency conflicts.
        install_system 2>&1 | tee "${LOG_DIR}/system.log"
    fi
    PYTHON="${AD_PYTHON:-$(command -v python3)}"
    PYTHON="$("$PYTHON" -c 'import sys; print(sys._base_executable)')"
    if ! verify_runtimes > "${LOG_DIR}/runtimes.log" 2>&1; then
        warn "Missing prerequisites; see ${LOG_DIR}/runtimes.log"
        exit 1
    fi
    selected python && install_python
    selected ruby && attempt evil-winrm install_ruby
    if selected standalone; then
        attempt kerbrute install_standalone kerbrute ropnop/kerbrute v1.0.3 \
            "^kerbrute_linux_${ARCH}$" "kerbrute_linux_${ARCH}"
        attempt chisel install_standalone chisel jpillora/chisel v1.12.0 \
            "^chisel_1\\.12\\.0_linux_${ARCH}\\.gz$" "chisel_1.12.0_linux_${ARCH}.gz"
        attempt ligolo-proxy install_standalone ligolo-proxy nicocha30/ligolo-ng v0.9.2 \
            "^ligolo-ng_proxy_0\\.9\\.2_linux_${ARCH}\\.tar\\.gz$" \
            "ligolo-ng_proxy_0.9.2_linux_${ARCH}.tar.gz" proxy
    fi
    selected repos && install_repos
    selected windows && install_windows
    selected powershell && install_powershell
    setup_path
    selected verify && verify_tools
    pipx list --json > "${LOG_DIR}/pipx-final.json"
    find "$BIN_DIR" "$SCRIPTS_DIR" -type f ! -path '*/.git/*' -print0 |
        sort -z | xargs -0 -r sha256sum > "${LOG_DIR}/artifacts.sha256"
    read -r SUCCEEDED FAILED SKIPPED < <(
        awk -F '\t' '
            $1 == "OK" {ok++} $1 == "FAIL" {fail++} $1 == "SKIP" {skip++}
            END {print ok+0, fail+0, skip+0}
        ' "$RESULTS"
    )
    printf '\nResults: %s OK, %s failed, %s skipped\nLogs: %s\n' \
        "$SUCCEEDED" "$FAILED" "$SKIPPED" "$LOG_DIR"
    # shellcheck disable=SC2016
    printf 'Open a new terminal or run: . "$HOME/.config/ad-tools/path.sh"\n'
    (( FAILED == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
