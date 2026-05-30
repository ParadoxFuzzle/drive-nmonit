#!/usr/bin/env bash
# =============================================================================
# Bash completion for drive-nmonit-cli
# =============================================================================
# Install:
#   sudo cp completions/drive-nmonit-cli.bash /etc/bash_completion.d/
#   # or source it directly:
#   source completions/drive-nmonit-cli.bash
#
# For user-level install:
#   mkdir -p ~/.local/share/bash-completion/completions
#   cp completions/drive-nmonit-cli.bash ~/.local/share/bash-completion/completions/drive-nmonit-cli
#
# For Homebrew/bash-completion@2:
#   cp completions/drive-nmonit-cli.bash "$(brew --prefix)/etc/bash_completion.d/"
# =============================================================================

_drive_nmonit_cli() {
    local cur prev words cword
    _init_completion -n ":" || return

    # Top-level commands
    local commands=(
        status:         "Display cluster status overview"
        health:         "Run health check"
        install:        "Install all dependencies"
        setup-mergerfs: "Set up local drive pooling (mergerfs)"
        setup-gluster:  "Initialize or join a GlusterFS cluster"
        gluster-join:   "Join the GlusterFS cluster as a slave"
        mount:          "Mount GlusterFS workspace volume"
        tune:           "Performance tuning (profile selection)"
        samba:          "Samba/CIFS share setup"
        nfs:            "NFS export setup"
        dashboard:      "Start/stop/restart web dashboard"        logs:          "View component logs"
        system-info:    "Show system information"
        init-config:    "Write an interactive config file"
        help:           "Show usage help"
    )

    # Commands that accept sub-options
    local health_opts="--json --nagios --quiet --watch --send-alert"
    local gluster_opts="--init --join"
    local dashboard_opts="--port --nodes --config --help"

    # Handle the current word being completed
    if [[ $cword -eq 1 ]]; then
        # First argument: complete the command
        if [[ "$cur" == --* ]]; then
            # Top-level flags (if any)
            COMPREPLY=($(compgen -W "--help --dry-run --no-dry-run --yes --confirm --config" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "${commands[*]%%:*}" -- "$cur"))
        fi
        [[ "${COMPREPLY[*]}" ]] && return
    fi

    # Past the first argument — complete sub-options based on the command
    local cmd="${words[1]}"

    # Map aliases to canonical command names
    case "$cmd" in
        info)          cmd="status" ;;
        check|checks)  cmd="health" ;;
        pool)          cmd="setup-mergerfs" ;;
        gluster-init)  cmd="setup-gluster" ;;
        join)          cmd="gluster-join" ;;
        tuning)        cmd="tune" ;;
        web)           cmd="dashboard" ;;
        sysinfo)       cmd="system-info" ;;
    esac

    # Abbreviations
    case "$cmd" in
        st|stat)       cmd="status" ;;
        he|hea)        cmd="health" ;;
        ins|inst|insta) cmd="install" ;;
        setup)         cmd="setup-mergerfs" ;;
        gl|glu|glust)  cmd="setup-gluster" ;;
        mo|moun)       cmd="mount" ;;
        tu|tun)        cmd="tune" ;;
        sa|sam|samb)   cmd="samba" ;;
        nf)            cmd="nfs" ;;
        da|dash|das|dashb) cmd="dashboard" ;;
        lo|log)        cmd="logs" ;;
        sy|sys|syst)   cmd="system-info" ;;
        in|ini|init)   cmd="init-config" ;;
        he)            cmd="help" ;;
    esac

    case "$cmd" in
        health)
            COMPREPLY=($(compgen -W "$health_opts" -- "$cur"))
            return
            ;;
        setup-gluster)
            COMPREPLY=($(compgen -W "$gluster_opts" -- "$cur"))
            return
            ;;
        dashboard)
            case "$prev" in
                --port)
                    # Complete common ports
                    COMPREPLY=($(compgen -W "8080 8081 9090 3000 8000" -- "$cur"))
                    return
                    ;;
                --nodes)
                    # Complete with @file for file paths or let user type
                    COMPREPLY=($(compgen -A hostname -- "$cur"))
                    return
                    ;;
                --config)
                    # Complete file paths
                    _filedir
                    return
                    ;;
            esac
            # If we're on the flag itself
            if [[ "$cur" == --* ]]; then
                COMPREPLY=($(compgen -W "$dashboard_opts" -- "$cur"))
            fi
            return
            ;;
        nfs|samba|setup-mergerfs|mount|gluster-join|status|install|tune|logs|system-info|init-config|help)
            # These commands take no additional flags — but support --config
            if [[ "$prev" == "--config" ]]; then
                _filedir
            elif [[ "$cur" == --* ]]; then
                COMPREPLY=($(compgen -W "--config" -- "$cur"))
            else
                COMPREPLY=()
            fi
            return
            ;;
    esac
}

# Register the completion function
if [[ -n "$BASH_VERSION" ]]; then
    complete -F _drive_nmonit_cli drive-nmonit-cli
    # Also register for the local path version
    complete -F _drive_nmonit_cli ./drive-nmonit-cli
fi
