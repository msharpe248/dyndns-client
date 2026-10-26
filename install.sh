#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s [--prefix DIRECTORY] [--launch-agent]\n' "$0"
    printf 'Install the existing release binary to DIRECTORY/bin (default: ~/.local/bin).\n'
    printf '%s\n' '--launch-agent installs or updates a per-user job that runs at login.'
}

prefix="$HOME/.local"
prefix_set=false
launch_agent=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            if [ "$#" -lt 2 ] || [ "$prefix_set" = true ]; then
                usage >&2
                exit 2
            fi
            prefix="$2"
            prefix_set=true
            shift 2
            ;;
        --launch-agent)
            if [ "$launch_agent" = true ]; then
                usage >&2
                exit 2
            fi
            launch_agent=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

case "$prefix" in
    /*) ;;
    *) printf 'Install prefix must be an absolute path: %s\n' "$prefix" >&2; exit 2 ;;
esac

project_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
binary="$project_dir/.build/release/dyndns-client"
if [ ! -x "$binary" ]; then
    printf 'Release binary not found. Run swift build -c release first.\n' >&2
    exit 1
fi

bin_dir="${prefix%/}/bin"
mkdir -p "$bin_dir"
install -m 755 "$binary" "$bin_dir/dyndns-client"
printf 'Installed %s\n' "$bin_dir/dyndns-client"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) printf 'Add %s to your PATH to run dyndns-client by name.\n' "$bin_dir" ;;
esac

if [ "$launch_agent" = true ]; then
    label=local.dyndns-client
    agent_dir="${DYNDNS_CLIENT_LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
    log_dir="${DYNDNS_CLIENT_LOG_DIR:-$HOME/Library/Logs}"
    launchctl_bin="${DYNDNS_CLIENT_LAUNCHCTL:-/bin/launchctl}"
    agent_plist="$agent_dir/$label.plist"
    mkdir -p "$agent_dir" "$log_dir"

    if [ -e "$agent_plist" ]; then
        existing_label=$(plutil -extract Label raw -o - "$agent_plist" 2>/dev/null || true)
        if [ "$existing_label" != "$label" ]; then
            printf 'Refusing to replace a plist with a different or unreadable label: %s\n' "$agent_plist" >&2
            exit 1
        fi
    fi

    temporary_plist=$(mktemp "$agent_dir/.$label.XXXXXX")
    trap 'if [ -e "$temporary_plist" ]; then unlink "$temporary_plist"; fi' EXIT
    plutil -create xml1 "$temporary_plist"
    plutil -insert Label -string "$label" "$temporary_plist"
    plutil -insert ProgramArguments -array "$temporary_plist"
    plutil -insert ProgramArguments.0 -string "$bin_dir/dyndns-client" "$temporary_plist"
    plutil -insert RunAtLoad -bool YES "$temporary_plist"
    plutil -insert StandardOutPath -string "$log_dir/dyndns-client.log" "$temporary_plist"
    plutil -insert StandardErrorPath -string "$log_dir/dyndns-client.error.log" "$temporary_plist"
    plutil -lint "$temporary_plist" >/dev/null
    chmod 600 "$temporary_plist"

    changed=true
    if [ -f "$agent_plist" ] && cmp -s "$temporary_plist" "$agent_plist"; then
        changed=false
    else
        mv "$temporary_plist" "$agent_plist"
    fi
    chmod 600 "$agent_plist"
    printf 'LaunchAgent %s: %s\n' "$agent_plist" "$(if [ "$changed" = true ]; then printf 'updated'; else printf 'unchanged'; fi)"

    user_domain="gui/$(id -u)"
    if "$launchctl_bin" print "$user_domain" >/dev/null 2>&1; then
        if "$launchctl_bin" print "$user_domain/$label" >/dev/null 2>&1; then
            if [ "$changed" = true ]; then
                "$launchctl_bin" bootout "$user_domain/$label"
                "$launchctl_bin" bootstrap "$user_domain" "$agent_plist"
                printf 'Reloaded %s\n' "$label"
            fi
        else
            "$launchctl_bin" bootstrap "$user_domain" "$agent_plist"
            printf 'Loaded %s\n' "$label"
        fi
    else
        printf 'No graphical login session is active; %s will load at next login.\n' "$label"
    fi
fi
