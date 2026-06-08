#!/usr/bin/env bash
set -euo pipefail

shortSleep=5
maxAttempts=5
longSleep=45
domain=""
LOG_FILE="${LOG_FILE:-get_git.log}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
AGENT_STARTED=0

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE"
}

# Load the SSH key into an agent ONCE. The "Enter passphrase for key ..."
# prompt from ssh-add is shown directly on this terminal; after that, every
# git operation reuses the cached key without prompting again.
startAgent() {
    [[ -f "$SSH_KEY" ]] || { log "no SSH key at $SSH_KEY; using existing auth"; return 0; }

    # Reuse the persistent agent keychain unlocked at login.
    local kc="$HOME/.keychain/$(uname -n)-sh"
    [[ -r "$kc" ]] && . "$kc"

    # ssh-add -l exit codes: 0 = has keys, 1 = agent up but empty, 2 = no agent
    local rc=0
    ssh-add -l &>/dev/null || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        eval "$(ssh-agent -s)" >/dev/null
        AGENT_STARTED=1
    fi

    # If this exact key is already loaded, don't re-prompt.
    local fp
    fp=$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}') || true
    if [[ -n "$fp" ]] && ssh-add -l 2>/dev/null | grep -qF "$fp"; then
        log "SSH key already loaded in agent"
        return 0
    fi

    log "Loading SSH key from $SSH_KEY (enter passphrase when prompted)"
    if ! ssh-add "$SSH_KEY"; then        # prompt is written straight to the tty
        log "ssh-add failed for $SSH_KEY"
        return 1
    fi
}

stopAgent() {
    if [[ "$AGENT_STARTED" == 1 ]]; then
        ssh-agent -k >/dev/null 2>&1 || true
    fi
}
trap stopAgent EXIT

# Validates the URL and extracts the host into the global `domain`.
# Handles https/http/ssh/git scheme URLs, scp-like git@host:path,
# and git@host/path.
getHost() {
    local url="$1"
    local schemeRe='^[a-zA-Z][a-zA-Z0-9+.-]*://([^/@]+@)?([^/:]+)'
    local scpRe='^([^/@]+@)?([^/:]+)[:/]'
    if [[ "$url" =~ $schemeRe ]]; then          # scheme form first
        domain="${BASH_REMATCH[2]}"
        return 0
    elif [[ "$url" =~ $scpRe ]]; then
        domain="${BASH_REMATCH[2]}"
        return 0
    fi
    log "ERROR: '$url' is not a recognizable git URL"
    return 1
}

# Reachability + access check for HTTPS and SSH. BatchMode stays on: by the
# time this runs the key is already in the agent, so it should never need to
# prompt; BatchMode just guarantees it fails fast instead of hanging.
checkRemote() {
    local url="$1"
    if GIT_TERMINAL_PROMPT=0 \
       GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new' \
       timeout 30 git ls-remote --quiet "$url" &>/dev/null; then
        return 0
    fi
    log "remote not reachable or access denied: $url"
    return 1
}

# 0 = mirror present & correct (or freshly cloned), 1 = error
checkGitDir() {
    local gitRepoLink="$1" gitDir="$2" remoteUrl
    if [[ -d "$gitDir" ]]; then
        log "$gitDir already exists"
    else
        mkdir -p "$gitDir"
        log "Created new dir at $gitDir"
    fi

    if git -C "$gitDir" rev-parse --is-bare-repository &>/dev/null; then
        remoteUrl=$(git -C "$gitDir" config --get remote.origin.url 2>/dev/null || true)
        if [[ "$remoteUrl" == "$gitRepoLink" ]]; then
            log "Existing mirror points at the correct remote"
            return 0
        fi
        log "ERROR: repo exists but points to '$remoteUrl' (expected '$gitRepoLink')"
        return 1
    fi

    log "No repo found; cloning a mirror"
    if git clone --mirror "$gitRepoLink" "$gitDir"; then
        return 0
    fi
    return 1
}

goGetIt() {
    local gitDir="$1"
    if git -C "$gitDir" fetch -p origin; then
        log "fetch successful"
        return 0
    fi
    log "fetch failed"
    return 1
}

throwIt() {
    local gitDir="$1" backUp="$2"
    if git -C "$gitDir" push --mirror "$backUp"; then
        log "push to backup successful"
        return 0
    fi
    log "push to backup failed"
    return 1
}

# retry <sleepSeconds> <function> [args...]
retry() {
    local sleepTime="$1"; shift
    local attempt=0 rc=1
    while (( attempt < maxAttempts )); do
        (( ++attempt ))
        if "$@"; then
            return 0
        fi
        rc=$?
        log "attempt $attempt/$maxAttempts failed (rc=$rc)"
        if (( attempt < maxAttempts )); then
            sleep "$sleepTime"
        fi
    done
    return "$rc"
}

main() {
    local originLink="${1:-}" localRepoDir="${2:-}" backUp="${3:-}"
    if [[ -z "$originLink" || -z "$localRepoDir" || -z "$backUp" ]]; then
        echo "usage: $0 <origin-url> <local-mirror-dir> <backup-remote-url>" >&2
        exit 2
    fi

    startAgent                                     || exit 1   # passphrase asked here, once
    getHost "$originLink"                          || exit 1
    retry "$longSleep"  checkRemote "$originLink"  || { log "origin ($domain) unreachable"; exit 1; }
    checkGitDir "$originLink" "$localRepoDir"       || exit 1
    retry "$shortSleep" goGetIt   "$localRepoDir"  || exit 1
    retry "$shortSleep" throwIt   "$localRepoDir" "$backUp" || exit 1

    log "Backup complete: $originLink -> $backUp"
}

main "$@"