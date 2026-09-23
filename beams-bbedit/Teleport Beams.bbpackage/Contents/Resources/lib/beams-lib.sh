#!/bin/bash
# beams-lib.sh — shared helpers for the Teleport Beams BBEdit package.
#
# Sourced by every item under Contents/Scripts and Contents/Text Filters.
# Not meant to be executed directly.
#
# Conventions
#   * Anything that can fail returns non-zero after showing its own error
#     dialog. Callers append `|| exit 1`. Because most helpers run inside
#     `$(...)`, they cannot exit the calling script themselves.
#   * All user interaction goes through osascript, addressed to BBEdit so
#     dialogs appear in front of the editor rather than behind it.
#   * `tsh beams exec` joins its argv into a single remote command line
#     (see beams_exec), so remote commands are always passed as one string.

set -o pipefail

BEAMS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEAMS_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teleport-beams-bbedit"
BEAMS_CONFIG_FILE="$BEAMS_CONFIG_DIR/config"
BEAMS_CURRENT_FILE="$BEAMS_CONFIG_DIR/current-beam"
BEAMS_HOME="/home/beams"
BEAMS_SSH_USER="beams"
BEAMS_HOST_PREFIX="bbedit--"
BEAMS_TITLE="Teleport Beams"

# BBEdit launches Unix scripts with a minimal PATH; make sure the usual
# install locations for tsh, python3 and jq are visible.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "$BEAMS_CONFIG_DIR"
# Optional user overrides (shell syntax): BEAMS_TSH, BEAMS_TERMINAL,
# BEAMS_GITHUB_USERNAME, BEAMS_GITHUB_EMAIL, BEAMS_GITHUB_AUTH.
# shellcheck disable=SC1090
[ -f "$BEAMS_CONFIG_FILE" ] && source "$BEAMS_CONFIG_FILE"

# Every run appends to a log so silent failures can be diagnosed: BBEdit only
# shows a script's stdout/stderr, and dialogs that fail to appear leave nothing.
BEAMS_LOG="$BEAMS_CONFIG_DIR/last-run.log"
{ [ -f "$BEAMS_LOG" ] && [ "$(wc -c <"$BEAMS_LOG")" -gt 200000 ] && : >"$BEAMS_LOG"; } 2>/dev/null
beams_log() {
    printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$BEAMS_LOG" 2>/dev/null
}
beams_log "=== $(basename "${0:-?}") pid=$$ PATH=$PATH BB_DOC_PATH=${BB_DOC_PATH:-} BB_DOC_NAME=${BB_DOC_NAME:-}"
# Mirror stderr into the log while still letting BBEdit display it.
exec 2> >(tee -a "$BEAMS_LOG" >&2)

# ---------------------------------------------------------------------------
# Dialogs
# ---------------------------------------------------------------------------

# beams_alert TITLE MESSAGE [critical|warning|informational]
beams_alert() {
    beams_log "alert: $2"
    local err
    err=$(mktemp)
    osascript - "$1" "$2" "${3:-informational}" >/dev/null 2>"$err" <<'EOF'
on run argv
    set {t, m, s} to argv
    tell application "BBEdit"
        activate
        if s is "critical" then
            display alert t message m as critical
        else if s is "warning" then
            display alert t message m as warning
        else
            display alert t message m
        end if
    end tell
end run
EOF
    if [ -s "$err" ]; then
        # The alert could not be shown — make sure the message still reaches the user.
        beams_log "alert failed: $(cat "$err")"
        printf '%s\n\n%s\n' "$1" "$2"
    fi
    rm -f "$err"
}

# beams_die MESSAGE — show an error alert (and echo it so it also lands in
# BBEdit's Unix Script Output window), return 1 (callers exit).
beams_die() {
    beams_alert "$BEAMS_TITLE" "$1" critical
    printf 'Error: %s\n' "$1"
    return 1
}

# beams_notify MESSAGE [SUBTITLE]
beams_notify() {
    osascript - "$1" "${2:-}" >/dev/null 2>&1 <<'EOF'
on run argv
    set {m, s} to argv
    if s is "" then
        display notification m with title "Teleport Beams"
    else
        display notification m with title "Teleport Beams" subtitle s
    end if
end run
EOF
}

# beams_osa_failed CONTEXT STDERR — log an osascript failure unless it was a
# plain Cancel (-128); surface anything else in BBEdit's output window.
beams_osa_failed() {
    case "$2" in
        *-128*) beams_log "$1: cancelled" ;;
        # stderr, not stdout: these helpers usually run inside $(...) and stdout
        # would be swallowed into the caller's variable.
        *) beams_log "$1: $2"; echo "Dialog failed ($1): $2" >&2 ;;
    esac
}

# beams_ask PROMPT [DEFAULT] [hidden] — prints the answer; non-zero on cancel.
# Tries the dialog hosted by BBEdit first; if that fails for any reason other
# than Cancel, retries as a plain osascript dialog.
beams_ask() {
    local out err msg
    err=$(mktemp)
    beams_log "ask: prompt=${#1}ch default=[${2:-}] mode=[${3:-}]"
    out=$(osascript - "$1" "${2:-}" "${3:-}" "bbedit" 2>"$err" <<'EOF'
on run argv
    set p to item 1 of argv
    set d to item 2 of argv
    set h to item 3 of argv
    set host to item 4 of argv
    if host is "bbedit" then
        tell application "BBEdit"
            activate
            if h is "hidden" then
                set r to display dialog p default answer d with title "Teleport Beams" with hidden answer
            else
                set r to display dialog p default answer d with title "Teleport Beams"
            end if
        end tell
    else
        if h is "hidden" then
            set r to display dialog p default answer d with title "Teleport Beams" with hidden answer
        else
            set r to display dialog p default answer d with title "Teleport Beams"
        end if
    end if
    return text returned of r
end run
EOF
    )
    if [ $? -ne 0 ]; then
        msg=$(cat "$err")
        case "$msg" in
            *-128*) rm -f "$err"; beams_log "ask: cancelled"; return 1 ;;
        esac
        beams_log "ask via BBEdit failed: $msg — retrying as plain dialog"
        out=$(osascript - "$1" "${2:-}" "${3:-}" "plain" 2>"$err" <<'EOF'
on run argv
    set p to item 1 of argv
    set d to item 2 of argv
    set h to item 3 of argv
    if h is "hidden" then
        set r to display dialog p default answer d with title "Teleport Beams" with hidden answer
    else
        set r to display dialog p default answer d with title "Teleport Beams"
    end if
    return text returned of r
end run
EOF
        ) || { beams_osa_failed "ask" "$(cat "$err")"; rm -f "$err"; return 1; }
    fi
    rm -f "$err"
    printf '%s' "$out"
}

# beams_confirm MESSAGE [BUTTON] — non-zero when the user cancels.
beams_confirm() {
    local err rc
    err=$(mktemp)
    osascript - "$1" "${2:-OK}" >/dev/null 2>"$err" <<'EOF'
on run argv
    set {m, b} to argv
    tell application "BBEdit"
        activate
        display dialog m buttons {"Cancel", b} default button b cancel button "Cancel" with title "Teleport Beams" with icon caution
    end tell
end run
EOF
    rc=$?
    [ $rc -ne 0 ] && beams_osa_failed "confirm" "$(cat "$err")"
    rm -f "$err"
    return $rc
}

# beams_choose PROMPT — items on stdin, one per line; prints the chosen line.
beams_choose() {
    local items err out
    items=$(cat)
    [ -n "$items" ] || return 1
    err=$(mktemp)
    out=$(osascript - "$1" "$items" 2>"$err" <<'EOF'
on run argv
    set {p, itemText} to argv
    set AppleScript's text item delimiters to linefeed
    set theItems to text items of itemText
    set AppleScript's text item delimiters to ""
    tell application "BBEdit"
        activate
        set r to choose from list theItems with prompt p with title "Teleport Beams" OK button name "Choose"
    end tell
    if r is false then error number -128
    return item 1 of r
end run
EOF
    ) || { beams_osa_failed "choose" "$(cat "$err")"; rm -f "$err"; return 1; }
    rm -f "$err"
    printf '%s' "$out"
}

# beams_choose_button MESSAGE BUTTON1 BUTTON2 [BUTTON3] — prints the button pressed.
beams_choose_button() {
    local err out
    err=$(mktemp)
    out=$(osascript - "$@" 2>"$err" <<'EOF'
on run argv
    set m to item 1 of argv
    set bs to rest of argv
    tell application "BBEdit"
        activate
        set r to display dialog m buttons bs default button (item (count of bs) of bs) with title "Teleport Beams"
    end tell
    return button returned of r
end run
EOF
    ) || { beams_osa_failed "buttons" "$(cat "$err")"; rm -f "$err"; return 1; }
    rm -f "$err"
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------

beams_find_tsh() {
    if [ -n "${BEAMS_TSH:-}" ] && [ -x "$BEAMS_TSH" ]; then
        printf '%s' "$BEAMS_TSH"; return 0
    fi
    if command -v tsh >/dev/null 2>&1; then
        command -v tsh; return 0
    fi
    local connect="/Applications/Teleport Connect.app/Contents/MacOS/tsh.app/Contents/MacOS/tsh"
    if [ -x "$connect" ]; then
        printf '%s' "$connect"; return 0
    fi
    return 1
}

beams_find_bbedit() {
    if command -v bbedit >/dev/null 2>&1; then
        command -v bbedit; return 0
    fi
    local helper="/Applications/BBEdit.app/Contents/Helpers/bbedit_tool"
    if [ -x "$helper" ]; then
        printf '%s' "$helper"; return 0
    fi
    return 1
}

if ! TSH="$(beams_find_tsh)"; then
    beams_alert "$BEAMS_TITLE" "tsh was not found. Install Teleport (https://goteleport.com/docs/installation/) or set BEAMS_TSH in $BEAMS_CONFIG_FILE." critical
    exit 1
fi
if ! BBEDIT="$(beams_find_bbedit)"; then
    beams_alert "$BEAMS_TITLE" "The bbedit command-line tool was not found. Install it from BBEdit → Install Command Line Tools." critical
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    beams_alert "$BEAMS_TITLE" "python3 was not found. Install the Xcode Command Line Tools (xcode-select --install) or Homebrew Python." critical
    exit 1
fi
export TSH BBEDIT

# ---------------------------------------------------------------------------
# Cluster pinning
# ---------------------------------------------------------------------------
# tsh acts on whatever profile is *current*, which changes whenever the user
# logs in to another cluster. Resolve the Beams cluster once (BEAMS_CLUSTER
# from the config file wins, then any *.beams.sh profile) and pass
# --proxy=<that cluster> on every tsh call so the package keeps working no
# matter which profile is current.

BEAMS_PREFERRED_CLUSTER="${BEAMS_CLUSTER:-}"
BEAMS_CLUSTER="" BEAMS_USERNAME="" BEAMS_PROXY="" BEAMS_VALID_UNTIL=""

beams_resolve_profile() {
    local json vars
    json=$("$TSH" status --format=json 2>/dev/null) || return 1
    vars=$(printf '%s' "$json" | python3 "$BEAMS_LIB_DIR/beams_json.py" profile "$BEAMS_PREFERRED_CLUSTER" 2>/dev/null) || return 1
    eval "$vars"
    [ -n "$BEAMS_CLUSTER" ]
}
beams_resolve_profile || true

# beams_tsh_raw ARGS... — tsh pinned to the Beams cluster; stderr passes through.
beams_tsh_raw() {
    if [ -n "$BEAMS_PROXY" ]; then
        "$TSH" --proxy="$BEAMS_PROXY" "$@"
    else
        "$TSH" "$@"
    fi
}

# beams_tsh_cmdline ARGS... — shell-quoted command line for a Terminal window.
beams_tsh_cmdline() {
    local out
    out=$(beams_shell_quote "$TSH")
    [ -n "$BEAMS_PROXY" ] && out+=" --proxy=$(beams_shell_quote "$BEAMS_PROXY")"
    local a
    for a in "$@"; do out+=" $(beams_shell_quote "$a")"; done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# beams_show TITLE [LANGUAGE] — stdin becomes a new, unmodified BBEdit document.
# Falls back to writing a file and opening it if the bbedit tool cannot reach
# BBEdit (which can happen while BBEdit is busy running this very script).
beams_show() {
    local title="$1" lang="${2:-}" tmp rc err
    tmp=$(mktemp "${TMPDIR:-/tmp}/beams-show.XXXXXX")
    cat >"$tmp"
    err=$(mktemp)
    if [ -n "$lang" ]; then
        "$BBEDIT" --clean --view-top -t "$title" -m "$lang" <"$tmp" 2>"$err"
    else
        "$BBEDIT" --clean --view-top -t "$title" <"$tmp" 2>"$err"
    fi
    rc=$?
    if [ $rc -ne 0 ]; then
        beams_log "bbedit tool failed rc=$rc: $(cat "$err")"
        local safe ext="txt"
        case "$lang" in Markdown) ext="md" ;; "Log File") ext="log" ;; esac
        safe=$(printf '%s' "$title" | tr -c 'A-Za-z0-9._-' '_')
        local out="$BEAMS_CONFIG_DIR/output/$safe.$ext"
        mkdir -p "$BEAMS_CONFIG_DIR/output"
        cp "$tmp" "$out"
        open -a BBEdit "$out" 2>>"$BEAMS_LOG" || echo "Could not open results in BBEdit; saved to $out"
        echo "Results saved to $out"
    else
        echo "Opened “$title” in BBEdit."
    fi
    rm -f "$tmp" "$err"
}

# beams_open_url SFTP_URL — open a remote file or folder in BBEdit.
beams_open_url() {
    local err rc
    err=$(mktemp)
    "$BBEDIT" "$1" 2>"$err"
    rc=$?
    if [ $rc -ne 0 ]; then
        beams_log "bbedit tool could not open $1 rc=$rc: $(cat "$err")"
        if open -a BBEdit "$1" 2>>"$BEAMS_LOG"; then
            echo "Opened $1 (via open -a BBEdit)."
        else
            rm -f "$err"
            beams_die "BBEdit could not open $1

$(cat "$err" 2>/dev/null)
See $BEAMS_LOG for details."
            return 1
        fi
    else
        echo "Opened $1"
    fi
    rm -f "$err"
}

# beams_strip_ansi — remove colour escapes from tsh output.
beams_strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

# beams_shell_quote VALUE — single-quote for the remote shell.
beams_shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ---------------------------------------------------------------------------
# tsh
# ---------------------------------------------------------------------------

# beams_tsh ARGS... — run tsh; on failure show the error and return non-zero.
beams_tsh() {
    local err rc msg
    err=$(mktemp)
    beams_log "tsh $*"
    beams_tsh_raw "$@" 2>"$err"
    rc=$?
    if [ $rc -ne 0 ]; then
        msg=$(beams_strip_ansi <"$err" | grep -v '^\s*$' | tail -6)
        beams_log "tsh failed rc=$rc: $msg"
        rm -f "$err"
        if printf '%s' "$msg" | grep -qiE 'not logged in|relogin|expired|no current profile|tsh login|certificate has expired'; then
            beams_die "Not logged in to Teleport${BEAMS_CLUSTER:+ cluster $BEAMS_CLUSTER}.

$msg

Use “Login…” in the Teleport Beams scripts menu, then try again."
        elif printf '%s' "$msg" | grep -qiE 'unknown service.*BeamService|does not implement this feature'; then
            beams_die "The Teleport cluster ${BEAMS_CLUSTER:-in use} does not offer Beams.

$msg

Use “Login…” with your Beams cluster (for example <name>.beams.sh); the package remembers it in $BEAMS_CONFIG_FILE as BEAMS_CLUSTER."
        else
            beams_die "tsh $1 $2 failed:

$msg"
        fi
        return $rc
    fi
    rm -f "$err"
}

# beams_exec BEAM_ID COMMAND_STRING — run a command on the beam, stdout passes through.
# tsh joins argv into one remote command line, so pass a single string and quote
# any user-supplied values with beams_shell_quote.
beams_exec() {
    local id="$1"; shift
    beams_tsh beams exec "$id" -- "$*"
}

# beams_exec_script BEAM_ID — run the script on stdin with bash on the beam.
beams_exec_script() {
    beams_tsh beams exec "$1" -- bash -s
}

# beams_profile — ensure BEAMS_CLUSTER, BEAMS_USERNAME, BEAMS_PROXY are known,
# or show the login error.
beams_profile() {
    [ -n "$BEAMS_CLUSTER" ] && return 0
    if beams_resolve_profile; then
        return 0
    fi
    beams_die "Not logged in to Teleport${BEAMS_PREFERRED_CLUSTER:+ cluster $BEAMS_PREFERRED_CLUSTER}.

Use “Login…” in the Teleport Beams scripts menu."
}

# beams_remember_cluster CLUSTER — persist the Beams cluster in the config file.
beams_remember_cluster() {
    {
        grep -v '^BEAMS_CLUSTER=' "$BEAMS_CONFIG_FILE" 2>/dev/null
        printf 'BEAMS_CLUSTER=%s\n' "$(beams_shell_quote "$1")"
    } >"$BEAMS_CONFIG_FILE.tmp" && mv "$BEAMS_CONFIG_FILE.tmp" "$BEAMS_CONFIG_FILE"
}

# beams_list_tsv — id<TAB>expires<TAB>url<TAB>owner<TAB>region<TAB>uuid, one beam per line.
beams_list_tsv() {
    local json
    json=$(beams_tsh beams ls -f json) || return 1
    printf '%s' "$json" | python3 "$BEAMS_LIB_DIR/beams_json.py" beams
}

# beams_field TSV_LINE N — nth tab-separated field.
beams_field() {
    printf '%s' "$1" | cut -f"$2"
}

# ---------------------------------------------------------------------------
# Beam selection
# ---------------------------------------------------------------------------

beams_current_id() {
    [ -f "$BEAMS_CURRENT_FILE" ] && tr -d '[:space:]' <"$BEAMS_CURRENT_FILE"
    return 0
}

beams_set_current() {
    printf '%s\n' "$1" >"$BEAMS_CURRENT_FILE"
}

beams_clear_current() {
    rm -f "$BEAMS_CURRENT_FILE"
}

# beams_pick [PROMPT] — choose a beam from a list dialog; prints its id.
beams_pick() {
    local prompt="${1:-Choose a beam}" tsv menu choice
    tsv=$(beams_list_tsv) || return 1
    if [ -z "$tsv" ]; then
        beams_alert "$BEAMS_TITLE" "You have no beams. Use “Create Beam” first."
        return 1
    fi
    menu=$(printf '%s\n' "$tsv" | python3 "$BEAMS_LIB_DIR/beams_json.py" menu "$(beams_current_id)")
    choice=$(printf '%s\n' "$menu" | beams_choose "$prompt") || return 1
    printf '%s' "${choice%% *}"
}

# beams_require — the current beam if it still exists, otherwise pick one and
# remember it. Prints the id.
beams_require() {
    local cur tsv id
    cur=$(beams_current_id)
    if [ -n "$cur" ]; then
        tsv=$(beams_list_tsv) || return 1
        if printf '%s\n' "$tsv" | cut -f1 | grep -qx -- "$cur"; then
            printf '%s' "$cur"
            return 0
        fi
        beams_clear_current
    fi
    id=$(beams_pick "Choose a beam (this becomes the current beam)") || { echo "Cancelled." >&2; return 1; }
    beams_set_current "$id"
    printf '%s' "$id"
}

# beams_url BEAM_ID — published URL or empty.
beams_url() {
    local tsv
    tsv=$(beams_list_tsv) || return 1
    printf '%s\n' "$tsv" | awk -F'\t' -v id="$1" '$1 == id { print $3 }'
}

# beams_uuid BEAM_ID — the beam's UUID (principal of its host certificate) or empty.
beams_uuid() {
    local tsv
    tsv=$(beams_list_tsv) || return 1
    printf '%s\n' "$tsv" | awk -F'\t' -v id="$1" '$1 == id { print $6 }'
}

# ---------------------------------------------------------------------------
# SSH config (used by BBEdit's SFTP browser via /usr/bin/ssh)
# ---------------------------------------------------------------------------

beams_ssh_host() {
    printf '%s%s.%s' "$BEAMS_HOST_PREFIX" "$1" "$BEAMS_CLUSTER"
}

# beams_ensure_ssh BEAM_ID [UUID] — write/refresh the Host alias in ~/.ssh/config;
# prints the alias. Requires a logged-in profile. The beam's host certificate names
# <uuid>.<cluster>, so the UUID (looked up if not given) becomes the HostName and
# ssh validates the certificate against the cluster CA in tsh's known_hosts.
beams_ensure_ssh() {
    beams_profile || return 1
    local uuid="${2:-}" tshconf alias
    if [ -z "$uuid" ]; then
        uuid=$(beams_uuid "$1") || return 1
        [ -n "$uuid" ] || beams_log "no uuid for beam $1; alias will use the id hostname (host key prompts likely)"
    fi
    tshconf=$("$TSH" config --proxy "$BEAMS_CLUSTER" 2>/dev/null || true)
    alias=$(printf '%s' "$tshconf" | python3 "$BEAMS_LIB_DIR/ssh_config.py" ensure \
        --id "$1" --uuid "$uuid" --cluster "$BEAMS_CLUSTER" --proxy "$BEAMS_PROXY" \
        --username "$BEAMS_USERNAME" --tsh "$TSH" --user "$BEAMS_SSH_USER" \
        --prefix "$BEAMS_HOST_PREFIX") || {
        beams_die "Could not update ~/.ssh/config for beam “$1”."
        return 1
    }
    printf '%s' "$alias"
}

# beams_verify_ssh BEAM_ID — true when a strict, non-interactive connection succeeds.
beams_verify_ssh() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 \
        "$(beams_ssh_host "$1")" true >/dev/null 2>&1
}

# beams_remove_ssh BEAM_ID
beams_remove_ssh() {
    python3 "$BEAMS_LIB_DIR/ssh_config.py" remove --id "$1" --prefix "$BEAMS_HOST_PREFIX" >/dev/null 2>&1 || true
}

# beams_sftp_url BEAM_ID REMOTE_PATH — sftp:// URL BBEdit can open. BBEdit reads a
# single-slash path as relative to the login's home directory; an absolute path
# needs a second slash (sftp://user@host//home/beams/file).
beams_sftp_url() {
    local host
    host=$(beams_ensure_ssh "$1") || return 1
    printf 'sftp://%s@%s/%s' "$BEAMS_SSH_USER" "$host" "$2"
}

# ---------------------------------------------------------------------------
# Terminal
# ---------------------------------------------------------------------------

# beams_terminal COMMAND_STRING — run in a new Terminal (or iTerm) window.
beams_terminal() {
    case "${BEAMS_TERMINAL:-Terminal}" in
        iTerm|iTerm2|iterm|iterm2)
            osascript - "$1" >/dev/null 2>&1 <<'EOF'
on run argv
    tell application "iTerm"
        activate
        set w to (create window with default profile)
        tell current session of w to write text (item 1 of argv)
    end tell
end run
EOF
            ;;
        *)
            osascript - "$1" >/dev/null 2>&1 <<'EOF'
on run argv
    tell application "Terminal"
        activate
        do script (item 1 of argv)
    end tell
end run
EOF
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Beam helpers
# ---------------------------------------------------------------------------

# beams_repo_root BEAM_ID — first git repository under /home/beams, or empty.
beams_repo_root() {
    beams_tsh_raw beams exec "$1" -- "if git -C $BEAMS_HOME rev-parse --show-toplevel >/dev/null 2>&1; then git -C $BEAMS_HOME rev-parse --show-toplevel; else find $BEAMS_HOME -maxdepth 3 -name .git -type d -not -path '*/node_modules/*' 2>/dev/null | head -1 | xargs -r dirname; fi" 2>/dev/null | tr -d '\r' | head -1
}

# beams_require_repo BEAM_ID — repo root or an error dialog.
beams_require_repo() {
    local root
    root=$(beams_repo_root "$1")
    if [ -z "$root" ]; then
        beams_die "No git repository found under $BEAMS_HOME on beam “$1”.

Clone one first (for example with “Setup GitHub on Beam…”)."
        return 1
    fi
    printf '%s' "$root"
}

# beams_expires_in ISO8601 — human "3h 12m".
beams_expires_in() {
    python3 "$BEAMS_LIB_DIR/beams_json.py" expires "$1"
}

# beams_selection — current BBEdit selection (or whole document when nothing is selected).
beams_selection() {
    osascript 2>/dev/null <<'EOF'
tell application "BBEdit"
    if (count of text windows) is 0 then return ""
    tell front text window
        set s to selection as text
        if s is "" then set s to contents of text document 1 as text
    end tell
    return s
end tell
EOF
}
