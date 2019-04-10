# Space-separated list of paths to search for HOST directives:
SSH_CONFIG_PATHS=~/.ssh/config
# Maximum number of ControlMaster connections to open:
MAX_CM_OPEN=1
# If there are more than MAX_CM_OPEN connections possible, use this heuristic to select the servers to connect to:
HEURISTIC="last-n-conn"
HEURISTIC_CACHE_LNC=~/.ssh_last_n

dbgecho() {
    # Comment these out to disable printing debug messages:
    echo "$@" >> debug.log
}

function __maybe_make_cache_lnc() {
    # TODO: Run this if the cache is old or if the SSH config file is newer than the cache.

    local TS_CACHE TS_CONFIG CFG TS_CFG

    TS_CACHE=$(stat -c %Y $HEURISTIC_CACHE_LNC)
    TS_CONFIG=$(date -d "-1 day" +%s) # One day ago; this way we renew the cache daily
    for CFG in $SSH_CONFIG_PATHS; do
        TS_CFG=$(stat -c %Y $CFG)
        (( $TS_CFG > $TS_CONFIG )) && TS_CONFIG=$TS_CFG
    done

    if [ $TS_CONFIG -gt $TS_CACHE ]; then
        __make_cache_lnc "$@"
    fi
}

function __make_cache_lnc() {
    local HOSTS
    HOSTS=("$@")

    (
        if flock -n 199; then
            local ORDERED
            ORDERED=()
            for LINE in $(fc -rl -3000 | grep '^[^a-zA-Z]*ssh'); do
                # dbgecho "SEARCHING FOR ${HOST[@]} IN $LINE"
                for HOST in "${HOSTS[@]}"; do
                    if [ ! -z "$HOST" ] && [[ $LINE == *$HOST* ]]; then
                        dbgecho "ORDERED B: $HOST"
                        ORDERED+=($HOST)
                        HOSTS=("${HOSTS[@]/$HOST}")
                        break
                    fi
                done

                if [ "${#HOSTS[@]}" = 0 ]; then
                    break
                fi
            done

            # Write output to cache:
            printf "%s\n" "${ORDERED[@]}" > "$HEURISTIC_CACHE_LNC"
            dbgecho "ORDERED: ${ORDERED[@]}"

            rm "$HEURISTIC_CACHE_LNC.lock"
        else
            dbgecho "LNC :: CANNOT ACQUIRE CACHE LOCK"
        fi
    ) 199>"$HEURISTIC_CACHE_LNC.lock"

}

function __open_conn() {
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
    ( ssh -MNnf -oBatchMode=yes "$SRVSTR" >/dev/null 2>&1 & )
}

function _ssh() 
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
        if [ "$HEURISTIC" = "last-n-conn" ]; then
            __maybe_make_cache_lnc ${HOSTS[@]}
            # Read in the cache
            local NEW_TARGETS
            NEW_TARGETS=()
            # Store in $NEW_TARGETS the first $MAX_CM_OPEN lines of $HEURISTIC_CACHE_LNC that appear in $TARGETS
            while read LNC || [[ -n "$LNC" ]]; do
                for TARGET in ${TARGETS[@]}; do
                    if [ ! -z "$TARGET" ] && [ $LNC = $TARGET ]; then
                        dbgecho "LNC: $TARGET"
                        NEW_TARGETS+=($TARGET)
                        TARGETS=("${TARGETS[@]/$TARGET}")
                        break
                    fi
                done

                if [ "${#NEW_TARGETS[@]}" -ge "$MAX_CM_OPEN" ]; then
                    break
                fi
            done < "$HEURISTIC_CACHE_LNC"

            # Update targets:
            TARGETS=(${NEW_TARGETS[@]})
            dbgecho "TARGETS [LNC]: ${NEW_TARGETS[@]}"

        else
            dbgecho "NO HEURISTIC; ABANDONING ATTEMPT"
            return 128
        fi
    fi

    dbgecho "TARGETS: ${TARGETS[@]}"
    for TARGET in "${TARGETS[@]}"; do
        __open_conn "$TARGET" $LAST_USER
    done

    return 0
}
complete -F _ssh ssh
