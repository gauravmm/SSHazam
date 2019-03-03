_ssh() 
{
    local SSH_CONFIG_PATHS MAX_CM_OPEN
    # Space-separated list of paths to search for HOST directives:
    SSH_CONFIG_PATHS=~/.ssh/config
    # Maximum number of ControlMaster connections to open:
    MAX_CM_OPEN=1

    local HOSTS SUPPORTS_CONTROL_MASTER
    COMPREPLY=()
    HOSTS=$(grep '^Host' $SSH_CONFIG_PATHS 2>/dev/null | grep -v '[?*]' | cut -d ' ' -f 2-)

    COMPREPLY=( $(compgen -W "$HOSTS" -- ${COMP_WORDS[COMP_CWORD]}) )
    # Now COMPREPLY contains the list of matching hosts.

    # Start an SSH  (-M) master connection, (-N) do not execute anything, (-n) do not read anything from stdin, (-f) go to background, (-oBatchMode) fail rather than ask for a password
    # $(ssh -MNnf -oBatchMode=yes -oControlMaster=auto <arg> &)
    grep '^\w*ControlMaster=(auto|yes)' $SSH_CONFIG_PATHS 2>/dev/null
    SUPPORTS_CONTROL_MASTER=$?

    if [ $SUPPORTS_CONTROL_MASTER ] && [ ${#COMPREPLY[@]} -le $MAX_CM_OPEN ]; then
        echo "OPEN CONTROLMASTER CONNECTION TO ${COMPREPLY[*]}"
        # xargs -P "$MAX_CM_OPEN" -n 1 -0 ssh -MNnf -oBatchMode=yes -oControlMaster=auto &
    fi

    return 0
}
complete -F _ssh ssh
