# Space-separated list of paths to search for HOST directives:
SSH_CONFIG_PATHS=~/.ssh/config

dbgecho() {
    echo "$@"
}

__open_conn() {
    local SRVSTR CMPATH
    SRVSTR="$2@$1"
    SRVSTR="${SRVSTR#@}" # Remove leading connection if it exists

    # Check if controlmaster is supported
    CMSUPPORT=$(ssh -G $SRVSTR | grep '^controlmaster ')
    CMSUPPORT=${CMSUPPORT#controlmaster } # Remove leading controlmaster
    if [ -z "$CMSUPPORT" ] || [ "$CMSUPPORT" == "false" ]; then
        dbgecho "CONTROLMASTER DISABLED FOR $SRVSTR!"
        return 255
    fi

    # Get controlmaster path
    CMPATH=$(ssh -G $SRVSTR | grep '^controlpath ')
    CMPATH=${CMPATH#controlpath } # Remove leading controlpath
    if [ -S $CMPATH ]; then
        # If it is a socket, check to see if it is connected
        # Note that the $SRVSTR argument is just filler.
        if ssh -S "$CMPATH" -O check "$SRVSTR" >/dev/null 2>&1 ; then
            dbgecho "CONTROLMASTER FOR $SRVSTR ALREADY OPEN!"
            return 0
        fi
    fi

    dbgecho "OPEN CONTROLMASTER CONNECTION TO $SRVSTR"
    # Start an SSH  (-M) master connection, (-N) do not execute anything, (-n) do not read anything from stdin, (-f) go to background, (-oBatchMode) fail rather than ask for a password
    ( ssh -MNnf -oBatchMode=yes "$SRVSTR" & )
}

_ssh() 
{
    local MAX_CM_OPEN LAST_WORD
    # Maximum number of ControlMaster connections to open:
    MAX_CM_OPEN=1

    LAST_WORD="${COMP_WORDS[COMP_CWORD]}"
    LAST_SERVER="${LAST_WORD#*@}"

    # Check if a username is specified:
    case "${LAST_WORD%$LAST_SERVER}" in
        *@) LAST_USER="${LAST_WORD%@}";; # If the string is <user>@<servername>, keep the <user>
        *)  LAST_USER="";; # Otherwise, we don't know <user>
    esac

    local HOSTS
    COMPREPLY=()
    HOSTS=$(grep '^Host' $SSH_CONFIG_PATHS 2>/dev/null | grep -v '[?*]' | cut -d ' ' -f 2-)
    COMPREPLY=( $(compgen -W "$HOSTS" -- $LAST_SERVER) )
    # Now COMPREPLY contains the list of matching hosts.

    if [ ${#COMPREPLY[@]} -le $MAX_CM_OPEN ]; then
        for TARGET in "${COMPREPLY[@]}"; do
            __open_conn "$TARGET" $LAST_USER
        done
    fi

    return 0
}
complete -F _ssh ssh
