# Space-separated list of paths to search for HOST directives:
SSH_CONFIG_PATHS=~/.ssh/config
# Maximum number of ControlMaster connections to open:
MAX_CM_OPEN=1
# Set to any non-blank value to enable debugging
DEBUG=""

# If there are more than MAX_CM_OPEN connections possible, use this heuristic to select the servers to connect to:
HEURISTIC="last" # "" "last" "most"
HEURISTIC_CACHE_LNC=~/.ssh_last_n
HEURISTIC_CACHE_MC=~/.ssh_most

dbgecho() {
    # Comment these out to disable printing debug messages:
    [ ! -z "$DEBUG" ] && echo "$@" >> debug.log
}

function __maybe_make_cache() {
    local CACHE_FILE
    CACHE_FILE="$1"

    local TS_CACHE TS_CONFIG CFG TS_CFG

    TS_CACHE=$(stat -c %Y "$CACHE_FILE")
    TS_CONFIG=$(date -d "-1 day" +%s) # One day ago; this way we renew the cache daily
    for CFG in $SSH_CONFIG_PATHS; do
        TS_CFG=$(stat -c %Y $CFG)
        (( $TS_CFG > $TS_CONFIG )) && TS_CONFIG=$TS_CFG
    done

    return [ $TS_CONFIG -gt $TS_CACHE ];
}

# Selected Connections
OPEN_CONN=()
function __select_conn() {
    local HEURISTIC_FILE CANDIDATES
    HEURISTIC_FILE="$1"
    shift
    CANDIDATES=( "$@" )

    local LNC TARGET
    # Read in the cache
    # Store in $OPEN_CONN the first $MAX_CM_OPEN lines of $HEURISTIC_FILE that appear in $CANDIDATES
    OPEN_CONN=()
    while read LNC || [[ -n "$LNC" ]]; do
        for TARGET in ${CANDIDATES[@]}; do
            if [ ! -z "$TARGET" ] && [ $LNC = $TARGET ]; then
                dbgecho "LNC: $TARGET"
                NEW_CANDIDATES+=($TARGET)
                CANDIDATES=("${CANDIDATES[@]/$TARGET}")
                break
            fi
        done

        if [ "${#OPEN_CONN[@]}" -ge "$MAX_CM_OPEN" ]; then
            break
        fi
    done < "$HEURISTIC_FILE"
}

#
# MOST-CONNECTED
#
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


#
# LAST-N-CONNECTIONS
#
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

#
# MAIN
#
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
    dbgecho ""
    dbgecho "*********************"

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
    dbgecho "COMPREPLY ${#COMPREPLY[@]}: ${COMPREPLY[@]/#/-> }"
    # Now COMPREPLY contains the list of matching hosts.

    if [ "${#TARGETS[@]}" -gt $MAX_CM_OPEN ]; then
        dbgecho "TOO MANY TARGETS: MAX_CM_OPEN: $MAX_CM_OPEN"
        local NEW_TARGETS
        NEW_TARGETS=()

        if [ "$HEURISTIC" = "last" ]; then
            if __maybe_make_cache "$HEURISTIC_CACHE_LNC"; then
                __make_cache_lnc ${HOSTS[@]}
            fi
            __select_conn "$HEURISTIC_CACHE_LNC" ${TARGETS[@]}

        if [ "$HEURISTIC" = "most" ]; then
            if __maybe_make_cache "$HEURISTIC_CACHE_MC"; then
                __make_cache_mc ${HOSTS[@]}
            fi
            __select_conn "$HEURISTIC_CACHE_MC" ${TARGETS[@]}

        else
            dbgecho "NO HEURISTIC; ABANDONING ATTEMPT"
            return 128
        fi
    else
        # Open all connections:
        OPEN_CONN=( ${TARGETS[@]} )
    fi

    dbgecho "OPEN_CONN: ${OPEN_CONN[@]}"
    for TARGET in "${OPEN_CONN[@]}"; do
        __open_conn "$TARGET" "$LAST_USER"
    done

    return 0
}
complete -F _ssh ssh
