# Space-separated list of paths to search for HOST directives:
SSH_CONFIG_PATHS=~/.ssh/config
# Maximum number of ControlMaster connections to open:
MAX_CM_OPEN=3
# To enable debugging, run `touch debug.log`.

# If there are more than MAX_CM_OPEN connections possible, use this heuristic to select the servers to connect to:
HEURISTIC="most" # "" "last" "most"
HEURISTIC_CACHE_LNC=~/.ssh_last_n
HEURISTIC_CACHE_MC=~/.ssh_most


# Compatibility mode:
OUTPUT_WITHOUT_ATPREFIX=false
if [[ "$BASH_VERSION" == 3.2.* ]]; then
    OUTPUT_WITHOUT_ATPREFIX=true
    dbgecho "DETECTED BASH 3.2.X; USING OUTPUT_WITHOUT_ATPREFIX"
fi

#
# UTILITY FUNCTIONS
#

dbgecho() {
    # Comment these out to disable printing debug messages:
    [ -f "./debug.log" ] && echo "$@" >> "debug.log"
}


function firstcmd() {
    for ALTERNATIVE in "$@"; do
        if command -v "$ALTERNATIVE" 1>/dev/null 2>&1; then
            echo -n "$ALTERNATIVE"
            return
        fi
    done
    dbgecho "No Alternatives Found: $@"
}


# Binaries; automatically use the first binary that exists
BIN_STAT=$(firstcmd gstat stat)
BIN_SED=$(firstcmd gsed sed)
BIN_DATE=$(firstcmd gdate date)

dbgecho "SELECTED $BIN_STAT FOR stat"
dbgecho "SELECTED $BIN_SED FOR sed"
dbgecho "SELECTED $BIN_DATE FOR date"

# Global state:
OPEN_CONN=() # Connections to open
HOSTS=()     # All possible hosts 

# Check if the passed cache file is out-of-date:
function __maybe_make_cache() {
    local CACHE_FILE
    CACHE_FILE="$1"

    local TS_CACHE TS_CONFIG CFG TS_CFG

    [ -f "$CACHE_FILE" ] || return 0

    TS_CACHE=$($BIN_STAT -c %Y "$CACHE_FILE")
    TS_CONFIG=$($BIN_DATE -d "-1 day" +%s) # One day ago; this way we renew the cache daily
    for CFG in $SSH_CONFIG_PATHS; do
        TS_CFG=$($BIN_STAT -c %Y $CFG)
        (( $TS_CFG > $TS_CONFIG )) && TS_CONFIG=$TS_CFG
    done

    test $TS_CONFIG -gt $TS_CACHE
    return $?
}

# Given a heuristic file and candidates, select the $MAX_CM_OPEN highest-ranked connections to open:
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
            if [ ! -z "$TARGET" ] && [ "$LNC" = "$TARGET" ]; then
                dbgecho "SELECT CONN: $TARGET"
                OPEN_CONN+=( "$TARGET" )
                CANDIDATES=( "${CANDIDATES[@]/$TARGET}" )
                break
            fi
        done

        if [ "${#OPEN_CONN[@]}" -ge "$MAX_CM_OPEN" ]; then
            break
        fi
    done < "$HEURISTIC_FILE"
}

# Acquire a lock on the heuristic file; if successful, update the heuristic file the output of an arbitrary function
function __lock_update() {
    local HEURISTIC_FILE INNER_FUNC
    HEURISTIC_FILE="$1"
    INNER_FUNC="$2"
    HEURISTIC_FILE_LOCK="$HEURISTIC_FILE.lock"

    dbgecho "UPDATE FILE $HEURISTIC_FILE"
    (
        if flock -n 199; then
            # Call the inner function and write output to cache:
            $INNER_FUNC > "$HEURISTIC_FILE"
            rm "$HEURISTIC_FILE_LOCK"
            dbgecho "SUCCESFULLY UPDATED"
        else
            dbgecho "CANNOT ACQUIRE CACHE LOCK"
        fi
    ) 199>"$HEURISTIC_FILE_LOCK"
}

#
# HEURISTICS
#
function __heuristic_mc() {
    local CANDIDATES
    CANDIDATES=( ${HOSTS[@]} )

    local CANDIDATE_LIST=$(printf "|%s" "${CANDIDATES[@]}")
    CANDIDATE_LIST="${CANDIDATE_LIST#|}"
    local REGEX_REPLACE="s/^.*(${CANDIDATE_LIST}).*$/\1/"
    local REGEX_STRIPNUM="s/^[ ]*[0-9]+ (.*)$/\1/"

    local FREQLINES=( $(fc -rl -3000 | grep '^[^a-zA-Z]*ssh' | "$BIN_SED" -re "$REGEX_REPLACE" | sort | uniq -c | sort -nr | "$BIN_SED" -re "$REGEX_STRIPNUM") )

    dbgecho "MC CANDIDATES: ${FREQLINES[@]}"

    for LINE in ${FREQLINES[@]}; do
        for HOST in ${CANDIDATES[@]}; do
            if [ ! -z "$HOST" ] && [ "$LINE" = "$HOST" ]; then
                CANDIDATES=( "${CANDIDATES[@]/$HOST}" )
                dbgecho "    MC: $HOST"
                echo $HOST
                break
            fi
        done

        if [ "${#CANDIDATES[@]}" = 0 ]; then
            break
        fi
    done
}

function __heuristic_lnc() {
    local CANDIDATES
    CANDIDATES="${HOSTS[@]}"

    for LINE in $(fc -rl -3000 | grep '^[^a-zA-Z]*ssh'); do
        for HOST in "${CANDIDATES[@]}"; do
            if [ ! -z "$HOST" ] && [[ $LINE == *$HOST* ]]; then
                CANDIDATES=("${CANDIDATES[@]/$HOST}")
                dbgecho "    LNC: $HOST"
                echo $HOST
                break
            fi
        done

        if [ "${#CANDIDATES[@]}" = 0 ]; then
            break
        fi
    done
}

#
# MAIN
#

# Actually open the connection:
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

function _ssh() {
    dbgecho ""
    dbgecho "*********************"
    dbgecho "${COMP_WORDS[COMP_CWORD]}"

    local LAST_WORD LAST_SERVER LAST_USER

    LAST_WORD="${COMP_WORDS[COMP_CWORD]}"
    LAST_SERVER="${LAST_WORD#*@}"

    # Check if a username is specified:
    case "${LAST_WORD%$LAST_SERVER}" in
        *@) LAST_USER="${LAST_WORD%@$LAST_SERVER}";; # If the string is <user>@<servername>, keep the <user>
        *)  LAST_USER="";; # Otherwise, we don't know <user>
    esac

    HOSTS=$(grep -i '^Host' $SSH_CONFIG_PATHS 2>/dev/null | grep -v '[?*]' | cut -d ' ' -f 2-)

    local TARGETS
    TARGETS=( $(compgen -W "$HOSTS" -- $LAST_SERVER) )

    if [ "${#TARGETS[@]}" = 0 ]; then
        dbgecho "NO TARGETS FOUND"
        return 127
    fi

    dbgecho "TARGETS ${#TARGETS[@]}: ${TARGETS[@]/#/-> }"

    # If the username is defined, add that to the front of each suggested server:
    COMPREPLY=()
    if [ -z "$LAST_USER" ]; then 
        COMPREPLY=( "${TARGETS[@]}" )
    else
        if [ $OUTPUT_WITHOUT_ATPREFIX = true ]; then
            COMPREPLY=( "${TARGETS[@]/#/@}" )
        else
            COMPREPLY=( "${TARGETS[@]/#/$LAST_USER@}" )
        fi
    fi
    dbgecho "COMPREPLY ${#COMPREPLY[@]}: ${COMPREPLY[@]/#/-> }"
    # Now COMPREPLY contains the list of matching hosts.

    if [ "${#TARGETS[@]}" -gt $MAX_CM_OPEN ]; then
        dbgecho "TOO MANY TARGETS; USING HEURISTIC TO SELECT $MAX_CM_OPEN"

        if [ "$HEURISTIC" = "last" ]; then
            if __maybe_make_cache "$HEURISTIC_CACHE_LNC"; then
                __lock_update "$HEURISTIC_CACHE_LNC" __heuristic_lnc
            fi
            # Update OPEN_CONN using the LNC heuristic:
            __select_conn "$HEURISTIC_CACHE_LNC" ${TARGETS[@]}

        elif [ "$HEURISTIC" = "most" ]; then
            if __maybe_make_cache "$HEURISTIC_CACHE_MC"; then
                __lock_update "$HEURISTIC_CACHE_MC" __heuristic_mc
            fi
            # Update OPEN_CONN using the MC heuristic:
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
