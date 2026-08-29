#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)
AGENT="$ROOT/agent.py"
OUTPUT=${1:-"$ROOT/install.sh"}
MARKER='__CODER_AGENT_PY_EOF_7C9B5F2A__'

if [ ! -f "$AGENT" ]; then
    echo "error: agent.py not found next to gen_install.sh" >&2
    exit 1
fi

if grep -qxF "$MARKER" "$AGENT"; then
    echo "error: embedded payload marker occurs in agent.py" >&2
    exit 1
fi

cat >"$OUTPUT" <<'INSTALL_HEAD'
#!/bin/sh
set -eu

SYSTEM_TARGET=/usr/local/bin/coder
LOCAL_TARGET=${HOME:+$HOME/.local/bin/coder}
CURRENT_TARGET=$PWD/coder
platform=$(uname -s 2>/dev/null || printf 'unknown')

say() {
    printf '%s\n' "$*"
}

platform_notes() {
    if ! command -v python3 >/dev/null 2>&1; then
        say "Warning: python3 is required to run coder and was not found in PATH." >&2
    fi

    if [ "$platform" = Darwin ] && ! command -v sandbox-exec >/dev/null 2>&1; then
        say "Warning: sandbox-exec was not found; coder's default macOS sandbox is unavailable." >&2
    fi
}

finish_install() {
    say "Installed coder to $1"
    platform_notes
}

ask_yes_no() {
    # Prompts must use /dev/tty: stdin may contain the rest of this script when
    # invoked as `curl .../install.sh | sh`.
    prompt=$1
    default=${2:-yes}

    if [ "$default" = yes ]; then
        suffix='[Y/n]'
    else
        suffix='[y/N]'
    fi

    # Keep tty redirection inside a subshell. Some POSIX shells terminate the
    # whole script under `set -e` when a special builtin cannot open /dev/tty.
    if ! answer=$(
        (
            printf '%s %s ' "$prompt" "$suffix" >/dev/tty
            IFS= read -r tty_answer </dev/tty
            printf '%s' "$tty_answer"
        ) 2>/dev/null
    ); then
        return 2
    fi

    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        n|N|no|NO|No) return 1 ;;
        '') [ "$default" = yes ] ;;
        *)
            say "Please answer yes or no."
            ask_yes_no "$prompt" "$default"
            ;;
    esac
}

write_agent() {
    cat <<'__CODER_AGENT_PY_EOF_7C9B5F2A__'
INSTALL_HEAD

cat "$AGENT" >>"$OUTPUT"

cat >>"$OUTPUT" <<'INSTALL_TAIL'
__CODER_AGENT_PY_EOF_7C9B5F2A__
}

make_payload() {
    tmp_dir=${TMPDIR:-/tmp}
    if command -v mktemp >/dev/null 2>&1; then
        payload=$(mktemp "$tmp_dir/coder-agent.XXXXXX" 2>/dev/null || true)
    else
        payload=
    fi

    if [ -z "${payload:-}" ]; then
        # Portable fallback for older/minimal Unix systems where mktemp is
        # missing or uses incompatible flags. noclobber avoids overwriting an
        # existing file if the predictable candidate happens to exist.
        old_umask=$(umask)
        umask 077
        i=0
        while [ "$i" -lt 100 ]; do
            candidate="$tmp_dir/coder-agent.$$.${i}"
            if (set -C; : >"$candidate") 2>/dev/null; then
                payload=$candidate
                break
            fi
            i=$((i + 1))
        done
        umask "$old_umask"
    fi

    if [ -z "${payload:-}" ]; then
        say "Could not create a temporary file." >&2
        exit 1
    fi

    trap 'rm -f "$payload"' EXIT HUP INT TERM
    write_agent >"$payload"
    chmod 755 "$payload"
}

install_file() {
    src=$1
    dest=$2
    dest_dir=$(dirname "$dest")
    mkdir -p "$dest_dir"
    cp "$src" "$dest"
    chmod 755 "$dest"
}

install_local() {
    if [ -n "${LOCAL_TARGET:-}" ]; then
        if ask_yes_no "Install for this user to $LOCAL_TARGET?" yes; then
            install_file "$payload" "$LOCAL_TARGET"
            finish_install "$LOCAL_TARGET"
            case ":${PATH:-}:" in
                *":$HOME/.local/bin:"*) ;;
                *) say "Note: add $HOME/.local/bin to PATH to run 'coder' directly." ;;
            esac
            return 0
        else
            answer_status=$?
            if [ "$answer_status" -eq 2 ]; then
                # No controlling terminal (common in automation): prefer the
                # conventional per-user location without blocking.
                install_file "$payload" "$LOCAL_TARGET"
                finish_install "$LOCAL_TARGET"
                case ":${PATH:-}:" in
                    *":$HOME/.local/bin:"*) ;;
                    *) say "Note: add $HOME/.local/bin to PATH to run 'coder' directly." ;;
                esac
                return 0
            fi
        fi
    fi

    install_file "$payload" "$CURRENT_TARGET"
    finish_install "$CURRENT_TARGET"
}

make_payload

if [ "$(id -u)" -eq 0 ]; then
    install_file "$payload" "$SYSTEM_TARGET"
    finish_install "$SYSTEM_TARGET"
    exit 0
fi

if [ -d "$(dirname "$SYSTEM_TARGET")" ] && [ -w "$(dirname "$SYSTEM_TARGET")" ]; then
    install_file "$payload" "$SYSTEM_TARGET"
    finish_install "$SYSTEM_TARGET"
    exit 0
fi

if command -v sudo >/dev/null 2>&1; then
    if ask_yes_no "Install system-wide to $SYSTEM_TARGET using sudo?" yes; then
        system_dir=$(dirname "$SYSTEM_TARGET")
        if sudo mkdir -p "$system_dir" \
            && sudo cp "$payload" "$SYSTEM_TARGET" \
            && sudo chmod 755 "$SYSTEM_TARGET"; then
            finish_install "$SYSTEM_TARGET"
            exit 0
        fi
        say "System-wide installation failed; offering a local installation instead." >&2
    else
        answer_status=$?
        if [ "$answer_status" -eq 2 ]; then
            say "No interactive terminal available; installing without sudo."
        else
            say "System-wide installation declined."
        fi
    fi
else
    say "sudo is not available; offering a local installation instead."
fi

install_local
INSTALL_TAIL

chmod 755 "$OUTPUT"
printf 'Generated %s from %s\n' "$OUTPUT" "$AGENT"

RUN_SH="$ROOT/run.sh"
cat >"$RUN_SH" <<'RUN_HEAD'
#!/bin/sh
set -eu

say() { printf '%s\n' "$*"; }

if ! command -v python3 >/dev/null 2>&1; then
    say "error: python3 is required but was not found in PATH" >&2
    exit 2
fi

tmp_dir=${TMPDIR:-/tmp}
payload=
if command -v mktemp >/dev/null 2>&1; then
    payload=$(mktemp "$tmp_dir/coder-agent.XXXXXX" 2>/dev/null || true)
fi
if [ -z "${payload:-}" ]; then
    old_umask=$(umask)
    umask 077
    i=0
    while [ "$i" -lt 100 ]; do
        candidate="$tmp_dir/coder-agent.$$.${i}"
        if (set -C; : >"$candidate") 2>/dev/null; then
            payload=$candidate
            break
        fi
        i=$((i + 1))
    done
    umask "$old_umask"
fi
if [ -z "${payload:-}" ]; then
    say "error: could not create a temporary file" >&2
    exit 1
fi
trap 'rm -f "$payload"' EXIT HUP INT TERM

cat >"$payload" <<'__CODER_AGENT_PY_EOF_7C9B5F2A__'
RUN_HEAD
cat "$AGENT" >>"$RUN_SH"
cat >>"$RUN_SH" <<'RUN_TAIL'
__CODER_AGENT_PY_EOF_7C9B5F2A__

python3 "$payload" "$@"
RUN_TAIL
chmod 755 "$RUN_SH"
printf 'Generated %s from %s\n' "$RUN_SH" "$AGENT"

RUN_PS1="$ROOT/run.ps1"
cat >"$RUN_PS1" <<'PS_RUN_HEAD'
# Generated from agent.py by gen_install.sh. Do not edit the embedded payload.
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $AgentArgs
)
$ErrorActionPreference = 'Stop'

function Find-Python {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($null -ne $py) { return [PSCustomObject]@{ Exe = $py.Source; Prefix = @('-3') } }
    foreach ($name in @('python3', 'python')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return [PSCustomObject]@{ Exe = $cmd.Source; Prefix = @() } }
    }
    throw 'Python 3 was not found. Install Python 3 and ensure py, python3, or python is in PATH.'
}

$agentSource = @'
PS_RUN_HEAD
cat "$AGENT" >>"$RUN_PS1"
cat >>"$RUN_PS1" <<'PS_RUN_TAIL'
'@ # __CODER_AGENT_PY_EOF_7C9B5F2A__

$python = Find-Python
$tempFile = Join-Path ([IO.Path]::GetTempPath()) ("coder-agent-{0}.py" -f [Guid]::NewGuid().ToString('N'))
$utf8NoBom = New-Object Text.UTF8Encoding($false)
try {
    [IO.File]::WriteAllText($tempFile, $agentSource, $utf8NoBom)
    $launchArgs = @($python.Prefix) + @($tempFile)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        Write-Warning 'Windows sandboxing is not implemented; running coder with --no-sandbox.'
        $launchArgs += '--no-sandbox'
    }
    if ($null -ne $AgentArgs) { $launchArgs += @($AgentArgs) }
    & $python.Exe @launchArgs
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
}
finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}
if ($null -ne $MyInvocation.MyCommand.Path) { exit $code }
$global:LASTEXITCODE = $code
PS_RUN_TAIL
printf 'Generated %s from %s\n' "$RUN_PS1" "$AGENT"

INSTALL_PS1="$ROOT/install.ps1"
cat >"$INSTALL_PS1" <<'PS_INSTALL_HEAD'
# Generated from agent.py by gen_install.sh. Do not edit the embedded payload.
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-PythonCommand {
    if (Get-Command py -ErrorAction SilentlyContinue) { return 'py -3' }
    if (Get-Command python3 -ErrorAction SilentlyContinue) { return 'python3' }
    if (Get-Command python -ErrorAction SilentlyContinue) { return 'python' }
    throw 'Python 3 was not found. Install Python 3 before installing coder.'
}

$agentSource = @'
PS_INSTALL_HEAD
cat "$AGENT" >>"$INSTALL_PS1"
cat >>"$INSTALL_PS1" <<'PS_INSTALL_TAIL'
'@ # __CODER_AGENT_PY_EOF_7C9B5F2A__

$pythonCommand = Find-PythonCommand
$isAdmin = Test-Administrator
if ($isAdmin) {
    $binDir = Join-Path $env:ProgramFiles 'Coder\bin'
} else {
    $binDir = Join-Path $env:LOCALAPPDATA 'Coder\bin'
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$agentPath = Join-Path $binDir 'coder.py'
$cmdPath = Join-Path $binDir 'coder.cmd'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($agentPath, $agentSource, $utf8NoBom)

$wrapper = "@echo off`r`n$pythonCommand `"%~dp0coder.py`" --no-sandbox %*`r`n"
[IO.File]::WriteAllText($cmdPath, $wrapper, [Text.Encoding]::ASCII)

$scope = if ($isAdmin) { 'Machine' } else { 'User' }
$pathValue = [Environment]::GetEnvironmentVariable('Path', $scope)
$parts = @($pathValue -split ';' | Where-Object { $_ })
if ($parts -notcontains $binDir) {
    $newPath = if ([string]::IsNullOrEmpty($pathValue)) { $binDir } else { "$pathValue;$binDir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, $scope)
    $env:Path = "$env:Path;$binDir"
    Write-Host "Added $binDir to the $scope PATH."
}

Write-Warning 'Windows sandboxing is not implemented; the installed coder command uses --no-sandbox.'
Write-Host "Installed coder to $binDir"
Write-Host "Open a new terminal if 'coder' is not immediately found."
PS_INSTALL_TAIL
printf 'Generated %s from %s\n' "$INSTALL_PS1" "$AGENT"
