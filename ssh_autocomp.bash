# Space-separated list of paths to search for HOST directives:
SSH_CONFIG_PATHS=~/.ssh/config
# Maximum number of ControlMaster connections to open:
MAX_CM_OPEN=1
# If there are more than MAX_CM_OPEN connections possible, use this heuristic to select the servers to connect to:
HEURISTIC=""

dbgecho() {
    # Comment these out to disable printing debug messages:
    echo "$@" >> debug.log
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
    dbgecho "*"

    local LAST_WORD LAST_SERVER LAST_USER

    LAST_WORD="${COMP_WORDS[COMP_CWORD]}"
    LAST_SERVER="${LAST_WORD#*@}"

    # Check if a username is specified:
    case "${LAST_WORD%$LAST_SERVER}" in
        *@) LAST_USER="${LAST_WORD%@$LAST_SERVER}";; # If the string is <user>@<servername>, keep the <user>
        *)  LAST_USER="";; # Otherwise, we don't know <user>
    esac

    local HOSTS TARGETS
    COMPREPLY=()
    HOSTS=$(grep '^Host' $SSH_CONFIG_PATHS 2>/dev/null | grep -v '[?*]' | cut -d ' ' -f 2-)
    TARGETS=($(compgen -W "$HOSTS" -- $LAST_SERVER))

    if [ "${#TARGETS[@]}" = 0 ]; then
        dbgecho "NO TARGETS FOUND"
        return 127
    fi

    dbgecho "TARGETS ${#TARGETS[@]}: ${TARGETS[@]/#/-> }"

    # If the username is defined, add that to the front of each suggested server:
    if [ -z "$LAST_USER" ]; then 
        COMPREPLY=(${TARGETS[@]})
    else
        COMPREPLY=(${TARGETS[@]/#/$LAST_USER@})
    fi
    # Now COMPREPLY contains the list of matching hosts.

    dbgecho "COMPREPLY ${#COMPREPLY[@]}: ${COMPREPLY[@]/#/-> }"

    if [ "${#TARGETS[@]}" -gt $MAX_CM_OPEN ]; then
        dbgecho "TOO MANY TARGETS: MAX_CM_OPEN: $MAX_CM_OPEN"
        if [ "$HEURISTIC" = "last-n-connections" ]; then 
            echo "TODO"
        else
            dbgecho "NO HEURISTIC; ABANDONING ATTEMPT"
            return 128
        fi
    fi

    for TARGET in "${COMPREPLY[@]}"; do
        __open_conn "$TARGET" $LAST_USER
    done

    return 0
}
complete -F _ssh ssh
