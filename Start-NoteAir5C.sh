#!/usr/bin/env sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ASSISTANT="$SCRIPT_DIR/Start-NoteAir5C.ps1"

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    CYAN=$(printf '\033[36m')
    DIM=$(printf '\033[2m')
    RED=$(printf '\033[31m')
    RESET=$(printf '\033[0m')
else
    CYAN=''
    DIM=''
    RED=''
    RESET=''
fi

printf '\n%s╭────────────────────────────────────────────────────────────────────────╮%s\n' "$CYAN" "$RESET"
printf '%s│%s  BOOX / NOTE AIR 5C  ·  ROOT + RECOVERY ASSISTANT                   %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
printf '%s╰────────────────────────────────────────────────────────────────────────╯%s\n' "$CYAN" "$RESET"

if [ ! -f "$ASSISTANT" ]; then
    printf '%sAssistant not found:%s %s\n' "$RED" "$RESET" "$ASSISTANT" >&2
    exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
    PWSH=$(command -v pwsh)
else
    case "$(uname -s 2>/dev/null || printf unknown)" in
        Darwin)
            printf '%sPowerShell 7 is required on macOS.%s\n' "$RED" "$RESET" >&2
            if command -v brew >/dev/null 2>&1; then
                printf 'Install it with:  brew install --cask powershell\n' >&2
            else
                printf 'Install Homebrew first, then run:  brew install --cask powershell\n' >&2
            fi
            ;;
        Linux)
            printf '%sPowerShell 7 is required on Linux.%s\n' "$RED" "$RESET" >&2
            printf 'Use Microsoft’s instructions for your distribution:\n' >&2
            printf 'https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux\n' >&2
            ;;
        *)
            printf '%sThis launcher supports Linux and macOS.%s\n' "$RED" "$RESET" >&2
            ;;
    esac
    exit 1
fi

printf '%sLaunching the resumable guided console with PowerShell 7…%s\n\n' "$DIM" "$RESET"
exec "$PWSH" -NoLogo -NoProfile -File "$ASSISTANT" "$@"
