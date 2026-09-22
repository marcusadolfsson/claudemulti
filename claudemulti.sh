#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ClaudeMulti
#
# Multi-account Claude Code launcher / session manager.
#
# Accounts live under:
#
#   ~/.claude-accounts/
#       personal/
#       foawa/
#       work/
#       ...
#
# Features:
#
#   1. Start a fresh Claude session under any account
#   2. Resume a recent session under its current account
#   3. Transfer a session to another account and resume it
#   4. Detect running Claude instances in the same project/session
#   5. Back up everything in the destination before it is replaced
#
# Run with --help for the command-line shortcuts.
#
# Environment overrides:
#
#   CLAUDE_PROFILES_BASE="$HOME/.claude-accounts"
#   CLAUDEMULTI_LIMIT=30
#   CLAUDEMULTI_REMOTE_CONTROL=1
#
# Optional:
#
#   CLAUDEMULTI_INCLUDE_DEFAULT=1
#
# Includes ~/.claude as an account named "default".
#
# ============================================================

PROFILES_BASE="${CLAUDE_PROFILES_BASE:-$HOME/.claude-accounts}"
SESSION_LIMIT="${CLAUDEMULTI_LIMIT:-30}"
INCLUDE_DEFAULT="${CLAUDEMULTI_INCLUDE_DEFAULT:-0}"

# Remote Control: 1 = start every session with Remote Control on,
# 0 = leave it to each account's own settings.
#
# A session you named (with /rename or in the desktop app) is
# started with --remote-control "<name>", so the app shows your
# name; anything else gets the remoteControlAtStartup setting
# through --settings. Both apply to this launch only, and no
# account's settings.json is modified. Needs a claude.ai login.
REMOTE_CONTROL="${CLAUDEMULTI_REMOTE_CONTROL:-1}"

# Show sessions with nothing in them (set by --all).
SHOW_EMPTY=0

# List sessions from every directory, not just the current one
# (set by -g).
ALL_DIRS=0

CURRENT_DIR="$(realpath -m "$PWD")"

# The last version of each project memory file that a transfer
# synced, used as the common ancestor for three-way merges. Kept
# outside every account so Claude never loads it as a memory.
MEMORY_BASE_DIR="$PROFILES_BASE/.claudemulti/memory-base"

# Extra arguments passed through to claude (everything after --).
declare -a CLAUDE_ARGS=()

# Field separator for helper output. Not whitespace, so `read`
# keeps empty fields instead of collapsing them.
SEP=$'\x1f'

# ============================================================
# Basic helpers
# ============================================================

die() {
    echo "ERROR: $*" >&2
    exit 1
}

pretty_path() {
    local path="$1"

    if [[ -z "$path" ]]; then
        printf '%s' "unknown"
    elif [[ "$path" == "$HOME" ]]; then
        printf '~'
    elif [[ "$path" == "$HOME/"* ]]; then
        printf '~/%s' "${path#"$HOME"/}"
    else
        printf '%s' "$path"
    fi
}

short_id() {
    local id="$1"

    if [[ ${#id} -gt 8 ]]; then
        printf '%s...' "${id:0:8}"
    else
        printf '%s' "$id"
    fi
}

format_time() {
    local epoch="$1"

    date -d "@$epoch" "+%b %d %H:%M" 2>/dev/null \
        || printf '%s' "$epoch"
}

truncate_text() {
    local text="$1"
    local width="$2"

    if (( ${#text} > width )); then
        printf '%s...' "${text:0:$((width - 3))}"
    else
        printf '%s' "$text"
    fi
}

terminal_width() {
    local cols
    cols="$(tput cols 2>/dev/null || true)"

    if [[ "$cols" =~ ^[0-9]+$ ]] && (( cols >= 40 )); then
        printf '%s' "$cols"
    else
        printf '100'
    fi
}

# confirm PROMPT [DEFAULT]
#
# DEFAULT is "n" (the default) or "y": what Enter means.
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -rp "$prompt [y/N]: " answer
    fi

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

profile_name_from_dir() {
    local dir
    dir="$(realpath -m "$1")"

    if [[ "$dir" == "$(realpath -m "$HOME/.claude")" ]]; then
        printf 'default'
    else
        basename "$dir"
    fi
}

# Claude names a project's transcript directory after its cwd,
# with every non-alphanumeric character replaced by '-'.
encode_project_dir() {
    printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

# ============================================================
# Extract session information
#
# session_info WANT FILE...
#
# Prints one line per transcript, in the order given:
#
#   file <SEP> cwd <SEP> title <SEP> last prompt <SEP> empty <SEP> name
#
# title  = the /rename title if set, else Claude's generated title
# prompt = the last thing actually typed, skipping /commands and
#          the wrapper messages Claude logs as "user" entries
# empty  = 1 when nothing was typed and Claude never replied: a
#          session opened and closed with /exit, or a Remote
#          Control connection that never got a message
# name   = the /rename title only (also what a rename in the
#          desktop app writes), blank if never named
#
# WANT = 0 prints every file. WANT = N skips empty sessions and
# stops after N lines, so callers can pass a generous candidate
# list without paying for all of it.
#
# ============================================================

session_info() {
    python3 - "$@" <<'PY'
import json
import os
import re
import sys

SEP = "\x1f"

# Things Claude records as "user" messages that nobody typed.
NOISE = re.compile(
    r"^(<(command-|local-command-|bash-|task-notification|system-reminder"
    r"|user-prompt-submit-hook)|Caveat: |\[Request interrupted)"
)
SLASH_COMMAND = re.compile(r"^/[A-Za-z0-9:_-]+(\s|$)")

# Only JSON-parse lines that can matter. Skips the assistant
# and tool traffic that makes up most of a transcript.
MARKERS = (b'"custom-title"', b'"ai-title"', b'"last-prompt"', b'"type":"user"')


def clean(text):
    return re.sub(r"\s+", " ", text or "").strip()


def is_real_prompt(text):
    return bool(text) and not NOISE.match(text) and not SLASH_COMMAND.match(text)


def parse_json(raw):
    try:
        return json.loads(raw.decode("utf-8", errors="ignore"))
    except Exception:
        return None


def get_user_text(obj):
    if obj.get("type") != "user":
        return ""

    if obj.get("isMeta") or obj.get("isCompactSummary") or obj.get("isSidechain"):
        return ""

    message = obj.get("message")
    texts = []

    if isinstance(message, str):
        texts.append(message)

    elif isinstance(message, dict):
        content = message.get("content")

        if isinstance(content, str):
            texts.append(content)

        elif isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    text = item.get("text")

                    if isinstance(text, str):
                        texts.append(text)

    text = clean(" ".join(texts))

    return text if is_real_prompt(text) else ""


def info(path):
    cwd = ""
    custom_title = ""
    ai_title = ""
    last_prompt = ""
    last_user_text = ""

    # --------------------------------------------------------
    # cwd, near the BEGINNING of the transcript.
    # --------------------------------------------------------

    try:
        with open(path, "rb") as f:
            for _ in range(500):
                raw = f.readline()

                if not raw:
                    break

                obj = parse_json(raw)

                if isinstance(obj, dict):
                    value = obj.get("cwd")

                    if isinstance(value, str) and value:
                        cwd = value
                        break
    except Exception:
        pass

    # --------------------------------------------------------
    # Titles and last prompt, near the END. Search 512 KB, then
    # 2 MB, then 8 MB; never read a whole huge JSONL for a menu.
    # --------------------------------------------------------

    try:
        size = os.path.getsize(path)

        for window in (512 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024):
            start = max(0, size - window)

            with open(path, "rb") as f:
                f.seek(start)
                data = f.read()

            # Discard the partial first line.
            if start > 0:
                pos = data.find(b"\n")

                if pos != -1:
                    data = data[pos + 1:]

            for raw in reversed(data.splitlines()):
                if not any(marker in raw for marker in MARKERS):
                    continue

                obj = parse_json(raw)

                if not isinstance(obj, dict):
                    continue

                kind = obj.get("type")

                if kind == "custom-title":
                    custom_title = custom_title or clean(obj.get("customTitle"))

                elif kind == "ai-title":
                    ai_title = ai_title or clean(obj.get("aiTitle"))

                elif kind == "last-prompt":
                    if not last_prompt:
                        text = clean(obj.get("lastPrompt"))

                        if is_real_prompt(text):
                            last_prompt = text

                elif not last_user_text:
                    last_user_text = get_user_text(obj)

                if custom_title and last_prompt:
                    break

            if (custom_title or ai_title) and (last_prompt or last_user_text):
                break

            if start == 0:
                break
    except Exception:
        pass

    return cwd, custom_title or ai_title, last_prompt or last_user_text, custom_title


# Byte search, no JSON parsing. A real session has its first
# reply near the top, so this rarely reads far.
def has_reply(path):
    marker = b'"type":"assistant"'
    tail = b""

    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1024 * 1024)

                if not chunk:
                    return False

                if marker in tail + chunk:
                    return True

                tail = chunk[-len(marker):]
    except Exception:
        return True


want = int(sys.argv[1])
printed = 0

for path in sys.argv[2:]:
    cwd, title, prompt, name = info(path)
    empty = not prompt and not has_reply(path)

    if want and empty:
        continue

    fields = [path, cwd, title, prompt, "1" if empty else "0", name]
    print(SEP.join(value.replace(SEP, " ").replace("\n", " ") for value in fields))

    printed += 1

    if want and printed >= want:
        break
PY
}

# ============================================================
# Account discovery
# ============================================================

declare -a PROFILE_DIRS=()
declare -a PROFILE_NAMES=()

discover_profiles() {
    PROFILE_DIRS=()
    PROFILE_NAMES=()

    if [[ "$INCLUDE_DEFAULT" == "1" && -d "$HOME/.claude" ]]; then
        PROFILE_DIRS+=("$(realpath -m "$HOME/.claude")")
        PROFILE_NAMES+=("default")
    fi

    if [[ -d "$PROFILES_BASE" ]]; then
        while IFS= read -r -d '' dir; do
            PROFILE_DIRS+=("$(realpath -m "$dir")")
            PROFILE_NAMES+=("$(basename "$dir")")
        done < <(
            # Dot-directories are ClaudeMulti's own (.claudemulti),
            # not accounts.
            find "$PROFILES_BASE" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                ! -name '.*' \
                -print0 \
                2>/dev/null \
                | sort -z
        )
    fi

    [[ ${#PROFILE_DIRS[@]} -gt 0 ]] || {
        echo
        echo "No Claude accounts found."
        echo
        echo "Expected accounts under:"
        echo "  $PROFILES_BASE"
        echo
        echo "Example:"
        echo "  $PROFILES_BASE/personal"
        echo "  $PROFILES_BASE/foawa"
        echo
        exit 1
    }
}

RESOLVED_PROFILE_INDEX=""

# Exact account name, or an unambiguous prefix of one.
resolve_account() {
    local name="$1"
    local -a hits=()
    local i

    for i in "${!PROFILE_NAMES[@]}"; do
        if [[ "${PROFILE_NAMES[$i]}" == "$name" ]]; then
            RESOLVED_PROFILE_INDEX="$i"
            return 0
        fi

        if [[ "${PROFILE_NAMES[$i]}" == "$name"* ]]; then
            hits+=("$i")
        fi
    done

    if [[ ${#hits[@]} -eq 1 ]]; then
        RESOLVED_PROFILE_INDEX="${hits[0]}"
        return 0
    fi

    if [[ ${#hits[@]} -gt 1 ]]; then
        die "Account '$name' is ambiguous. Accounts: ${PROFILE_NAMES[*]}"
    fi

    die "No account named '$name'. Accounts: ${PROFILE_NAMES[*]}"
}

# ============================================================
# Session discovery
# ============================================================

declare -a SESSION_FILES=()
declare -a SESSION_IDS=()
declare -a SESSION_PROFILE_INDEXES=()
declare -a SESSION_TIMES=()
declare -a SESSION_CWDS=()
declare -a SESSION_TITLES=()
declare -a SESSION_PREVIEWS=()
declare -a SESSION_EMPTY=()
declare -a SESSION_NAMES=()

# ------------------------------------------------------------
# Print "mtime <TAB> profile index <TAB> file" for every session
# transcript in every account, unsorted.
#
# Transcripts sit exactly at projects/<project>/<id>.jsonl.
# Subagent transcripts live one level deeper, so the depth
# limit already excludes them; the UUID check catches strays.
# ------------------------------------------------------------

session_candidates() {
    local i

    for i in "${!PROFILE_DIRS[@]}"; do
        local projects="${PROFILE_DIRS[$i]}/projects"

        [[ -d "$projects" ]] || continue

        find "$projects" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name '*.jsonl' \
            -printf "%T@\t$i\t%p\n" \
            2>/dev/null \
            || true
    done | grep -E $'\t[^\t]*/[0-9a-fA-F-]{20,}\\.jsonl$' || true
}

# Only the candidates for the current directory. Claude files a
# project's transcripts under projects/<encoded cwd>/, so this
# matches exactly the sessions Claude's own /resume would show.
current_dir_candidates() {
    local encoded
    encoded="$(encode_project_dir "$CURRENT_DIR")"

    session_candidates \
        | awk -F'\t' -v dir="/projects/$encoded/" 'index($3, dir) > 0' \
        || true
}

list_candidates() {
    if [[ "$ALL_DIRS" == "1" ]]; then
        session_candidates
    else
        current_dir_candidates
    fi
}

# ------------------------------------------------------------
# load_sessions WANT
#
# Append sessions read from stdin ("mtime <TAB> index <TAB> file",
# newest first) to the SESSION_* arrays, with one python call for
# the batch. WANT is passed to session_info: 0 loads every file,
# N loads the first N that are not empty.
# ------------------------------------------------------------

load_sessions() {
    local want="$1"
    local -a files=()
    local -A index_of=()
    local -A time_of=()

    local mtime profile_index file

    while IFS=$'\t' read -r mtime profile_index file; do
        [[ -f "$file" ]] || continue

        files+=("$file")
        index_of["$file"]="$profile_index"
        time_of["$file"]="${mtime%.*}"
    done

    [[ ${#files[@]} -gt 0 ]] || return 0

    local cwd title preview empty

    local name

    while IFS="$SEP" read -r file cwd title preview empty name; do
        [[ -n "$file" && -n "${index_of[$file]:-}" ]] || continue

        SESSION_FILES+=("$file")
        SESSION_IDS+=("$(basename "$file" .jsonl)")
        SESSION_PROFILE_INDEXES+=("${index_of[$file]}")
        SESSION_TIMES+=("${time_of[$file]}")
        SESSION_CWDS+=("$cwd")
        SESSION_TITLES+=("$title")
        SESSION_PREVIEWS+=("$preview")
        SESSION_EMPTY+=("$empty")
        SESSION_NAMES+=("$name")
    done < <(session_info "$want" "${files[@]}")
}

discover_sessions() {
    SESSION_FILES=()
    SESSION_IDS=()
    SESSION_PROFILE_INDEXES=()
    SESSION_TIMES=()
    SESSION_CWDS=()
    SESSION_TITLES=()
    SESSION_PREVIEWS=()
    SESSION_EMPTY=()
    SESSION_NAMES=()

    # Empty sessions are hidden unless --all, and do not use up
    # a slot in the list.
    if [[ "$SHOW_EMPTY" == "1" ]]; then
        load_sessions 0 < <(
            list_candidates \
                | sort -t $'\t' -k1,1nr \
                | head -n "$SESSION_LIMIT"
        )
    else
        load_sessions "$SESSION_LIMIT" < <(
            list_candidates \
                | sort -t $'\t' -k1,1nr
        )
    fi
}

RESOLVED_SESSION_INDEX=""

# ------------------------------------------------------------
# resolve_session SELECTOR [ONLY_PROFILE_INDEX] [EXCLUDE_PROFILE_INDEX]
#
# SELECTOR is either a number from the session list, or a
# session ID / ID prefix (at least 4 characters).
#
# A transferred session exists in more than one account, so the
# profile filters are how the caller says which copy it means.
# ------------------------------------------------------------

resolve_session() {
    local selector="$1"
    local only="${2:-}"
    local exclude="${3:-}"

    if [[ "$selector" =~ ^[0-9]{1,3}$ ]]; then
        [[ ${#SESSION_FILES[@]} -gt 0 ]] || discover_sessions

        if (( selector < 1 || selector > ${#SESSION_FILES[@]} )); then
            die "No session number $selector (the list has ${#SESSION_FILES[@]})."
        fi

        RESOLVED_SESSION_INDEX=$((selector - 1))
        return 0
    fi

    [[ "$selector" =~ ^[0-9a-fA-F-]{4,}$ ]] \
        || die "'$selector' is not a session number or session ID."

    local first=${#SESSION_FILES[@]}

    load_sessions 0 < <(
        session_candidates \
            | awk -F'\t' -v p="$selector" -v only="$only" -v exclude="$exclude" '
                {
                    name = $3
                    sub(/.*\//, "", name)
                }
                index(name, p) != 1  { next }
                only != "" && $2 != only { next }
                exclude != "" && $2 == exclude { next }
                { print }
              ' \
            | sort -t $'\t' -k1,1nr
    )

    local last=${#SESSION_FILES[@]}
    local count=$((last - first))

    if (( count == 0 )); then
        if [[ -n "$only" ]]; then
            die "No session matching '$selector' in account '${PROFILE_NAMES[$only]}'."
        fi
        die "No session matching '$selector'."
    fi

    if (( count == 1 )); then
        RESOLVED_SESSION_INDEX="$first"
        return 0
    fi

    local k
    local distinct_ids
    distinct_ids="$(printf '%s\n' "${SESSION_IDS[@]:$first:$count}" | sort -u | wc -l)"

    echo >&2

    if (( distinct_ids == 1 )); then
        echo "Session ${SESSION_IDS[$first]} exists in more than one account:" >&2
    else
        echo "'$selector' matches more than one session:" >&2
    fi

    echo >&2

    for ((k = first; k < last; k++)); do
        printf '  %-12s %-13s %s  %s\n' \
            "${PROFILE_NAMES[${SESSION_PROFILE_INDEXES[$k]}]}" \
            "$(format_time "${SESSION_TIMES[$k]}")" \
            "${SESSION_IDS[$k]}" \
            "${SESSION_TITLES[$k]}" >&2
    done

    echo >&2

    if (( distinct_ids == 1 )); then
        die "Say which copy you mean with -a ACCOUNT."
    fi
    die "Use a longer ID prefix."
}

# ============================================================
# Running Claude detection
#
# Every running Claude registers itself in its account's
# sessions/<pid>.json, with the exact session ID and cwd:
#
#   {"pid":4077276,"sessionId":"dc5e…","cwd":"/home/…",
#    "status":"busy","procStart":"72412666",
#    "pidDomain":"linux:…:pid:[4026531836]",…}
#
# Entries can be stale (crashed process, recycled PID, or a
# container that shares the config dir), so an entry counts only
# if its PID namespace is ours and its PID's start time matches.
#
# Older Claude versions without that registry are still found
# through pgrep, with the session known only when it was started
# with an explicit `-r <id>`.
# ============================================================

running_sessions_from_registry() {
    python3 - "$@" <<'PY'
import glob
import json
import os
import sys

SEP = "\x1f"

try:
    my_pid_ns = os.readlink("/proc/self/ns/pid")
except OSError:
    my_pid_ns = ""

for config_dir in sys.argv[1:]:
    for path in sorted(glob.glob(os.path.join(config_dir, "sessions", "*.json"))):
        try:
            with open(path) as f:
                entry = json.load(f)
        except Exception:
            continue

        pid = entry.get("pid")

        if not isinstance(pid, int):
            continue

        domain = entry.get("pidDomain") or ""

        if my_pid_ns and domain and not domain.endswith(my_pid_ns):
            continue

        try:
            with open(f"/proc/{pid}/stat") as f:
                stat = f.read()
        except OSError:
            continue

        # Field 22 (starttime). Split after the last ')' because
        # the command name in field 2 may contain spaces.
        fields = stat[stat.rindex(")") + 2:].split()
        start_time = entry.get("procStart")

        if start_time is not None and len(fields) > 19 and str(start_time) != fields[19]:
            continue

        values = [
            str(pid),
            entry.get("sessionId") or "",
            entry.get("cwd") or "",
            entry.get("status") or "",
            entry.get("kind") or "",
            entry.get("tmux") or "",
            os.path.realpath(config_dir),
        ]

        print(SEP.join(str(v).replace(SEP, " ").replace("\n", " ") for v in values))
PY
}

process_config_dir() {
    local pid="$1"
    local config=""

    if [[ -r "/proc/$pid/environ" ]]; then
        config="$(
            tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                | sed -n 's/^CLAUDE_CONFIG_DIR=//p' \
                | head -n 1
        )" || true
    fi

    # If CLAUDE_CONFIG_DIR is not set, Claude uses ~/.claude.
    if [[ -z "$config" ]]; then
        config="$HOME/.claude"
    fi

    realpath -m "$config"
}

process_explicit_session() {
    local pid="$1"

    [[ -r "/proc/$pid/cmdline" ]] || return 0

    local -a argv=()

    mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || true

    local i

    for ((i = 0; i < ${#argv[@]}; i++)); do
        case "${argv[$i]}" in
            -r|--resume)
                if (( i + 1 < ${#argv[@]} )); then
                    local next="${argv[$((i + 1))]}"

                    if [[ -n "$next" && "$next" != -* ]]; then
                        printf '%s' "$next"
                        return 0
                    fi
                fi
                ;;

            --resume=*)
                printf '%s' "${argv[$i]#--resume=}"
                return 0
                ;;
        esac
    done
}

declare -a RUN_PIDS=()
declare -a RUN_SIDS=()
declare -a RUN_CWDS=()
declare -a RUN_STATUSES=()
declare -a RUN_KINDS=()
declare -a RUN_WHERE=()
declare -a RUN_CONFIGS=()
declare -A RUNNING_BY_SID=()

discover_running() {
    RUN_PIDS=()
    RUN_SIDS=()
    RUN_CWDS=()
    RUN_STATUSES=()
    RUN_KINDS=()
    RUN_WHERE=()
    RUN_CONFIGS=()
    RUNNING_BY_SID=()

    # Always look at ~/.claude too: a Claude started without
    # CLAUDE_CONFIG_DIR can still be sitting in the same project.
    local -a config_dirs=("${PROFILE_DIRS[@]}")
    local default_dir
    default_dir="$(realpath -m "$HOME/.claude")"

    local dir
    local have_default=0

    for dir in "${PROFILE_DIRS[@]}"; do
        if [[ "$dir" == "$default_dir" ]]; then
            have_default=1
        fi
    done

    if (( ! have_default )) && [[ -d "$default_dir" ]]; then
        config_dirs+=("$default_dir")
    fi

    local pid sid cwd status kind tmux config

    while IFS="$SEP" read -r pid sid cwd status kind tmux config; do
        [[ -n "$pid" ]] || continue

        local where="$tmux"

        if [[ -n "$where" ]]; then
            where="tmux $where"
        else
            where="$(ps -o tty= -p "$pid" 2>/dev/null | xargs || true)"
        fi

        RUN_PIDS+=("$pid")
        RUN_SIDS+=("$sid")
        RUN_CWDS+=("$(realpath -m "${cwd:-/}")")
        RUN_STATUSES+=("$status")
        RUN_KINDS+=("$kind")
        RUN_WHERE+=("$where")
        RUN_CONFIGS+=("$config")

    done < <(running_sessions_from_registry "${config_dirs[@]}")

    # Fallback for Claude versions that predate the registry.
    while IFS= read -r pid; do
        [[ -n "$pid" && -d "/proc/$pid" ]] || continue

        local known=0 p

        for p in "${RUN_PIDS[@]}"; do
            if [[ "$p" == "$pid" ]]; then
                known=1
            fi
        done

        (( known )) && continue

        local proc_cwd
        proc_cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"

        [[ -n "$proc_cwd" ]] || continue

        RUN_PIDS+=("$pid")
        RUN_SIDS+=("$(process_explicit_session "$pid")")
        RUN_CWDS+=("$(realpath -m "$proc_cwd")")
        RUN_STATUSES+=("")
        RUN_KINDS+=("")
        RUN_WHERE+=("$(ps -o tty= -p "$pid" 2>/dev/null | xargs || true)")
        RUN_CONFIGS+=("$(process_config_dir "$pid")")

    done < <(pgrep -u "$USER" -x claude 2>/dev/null || true)

    local k

    for k in "${!RUN_PIDS[@]}"; do
        if [[ -n "${RUN_SIDS[$k]}" ]]; then
            RUNNING_BY_SID["${RUN_SIDS[$k]}"]="${RUN_PIDS[$k]}"
        fi
    done
}

print_running_entry() {
    local k="$1"
    local match="${2:-}"

    echo "  PID:      ${RUN_PIDS[$k]}"
    echo "  Where:    ${RUN_WHERE[$k]:-?}"
    echo "  Account:  $(profile_name_from_dir "${RUN_CONFIGS[$k]}")"
    echo "  Session:  ${RUN_SIDS[$k]:-unknown}"
    echo "  Project:  $(pretty_path "${RUN_CWDS[$k]}")"

    if [[ -n "${RUN_STATUSES[$k]}${RUN_KINDS[$k]}" ]]; then
        echo "  State:    ${RUN_STATUSES[$k]:-?}${RUN_KINDS[$k]:+ (${RUN_KINDS[$k]})}"
    fi

    if [[ -n "$match" ]]; then
        echo "  Match:    $match"
    fi

    echo
}

# ------------------------------------------------------------
# check_running_claude
#
# $1 = project cwd
# $2 = session id, or blank
# $3 = target account/profile dir, or blank
#
# Warns about:
#
#   the exact session, running anywhere
#   any Claude running in the same directory
#   (stronger: same project + account)
#
# Returns:
#
#   0 = safe / user chose to continue
#   1 = user cancelled
#
# ------------------------------------------------------------

check_running_claude() {
    local target_cwd
    target_cwd="$(realpath -m "$1")"

    local target_sid="${2:-}"
    local target_profile="${3:-}"

    if [[ -n "$target_profile" ]]; then
        target_profile="$(realpath -m "$target_profile")"
    fi

    discover_running

    local -a match_indexes=()
    local -a match_labels=()
    local exact_session_found=0
    local k

    for k in "${!RUN_PIDS[@]}"; do
        local label=""

        if [[ -n "$target_sid" && "${RUN_SIDS[$k]}" == "$target_sid" ]]; then
            label="EXACT SESSION"
            exact_session_found=1

        elif [[ "${RUN_CWDS[$k]}" == "$target_cwd" ]]; then
            if [[ -n "$target_profile" && "${RUN_CONFIGS[$k]}" == "$target_profile" ]]; then
                label="same project + account"
            else
                label="same project"
            fi
        fi

        if [[ -n "$label" ]]; then
            match_indexes+=("$k")
            match_labels+=("$label")
        fi
    done

    if [[ ${#match_indexes[@]} -eq 0 ]]; then
        return 0
    fi

    echo
    if (( exact_session_found )); then
        echo "WARNING: This session is already running"
    else
        echo "WARNING: Claude is already running in this project"
    fi
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "Project:"
    echo "  $(pretty_path "$target_cwd")"
    echo

    for k in "${!match_indexes[@]}"; do
        print_running_entry "${match_indexes[$k]}" "${match_labels[$k]}"
    done

    if (( exact_session_found )); then
        echo "!!! THE SAME SESSION IS RUNNING !!!"
        echo
        echo "Starting, resuming or transferring another copy creates"
        echo "diverging versions of the same conversation. Exit that"
        echo "Claude first."
    else
        echo "At least one Claude instance is already running"
        echo "from this same project directory."
    fi

    echo

    if confirm "Continue anyway?"; then
        return 0
    fi

    echo
    echo "Cancelled."
    return 1
}

show_running() {
    discover_running

    echo
    echo "Running Claude instances"
    echo "════════════════════════════════════════════════════════════════"
    echo

    if [[ ${#RUN_PIDS[@]} -eq 0 ]]; then
        echo "  None."
        echo
        return 0
    fi

    local k

    for k in "${!RUN_PIDS[@]}"; do
        print_running_entry "$k"
    done
}

# ============================================================
# Display recent sessions
# ============================================================

show_sessions() {
    discover_running

    local width
    width="$(terminal_width)"

    echo
    if [[ "$ALL_DIRS" == "1" ]]; then
        echo "Recent Claude sessions, all directories"
        echo "════════════════════════════════════════════════════════════════"
        echo
        echo "  * = session project matches current directory"
    else
        echo "Claude sessions in $(pretty_path "$CURRENT_DIR")"
        echo "════════════════════════════════════════════════════════════════"
    fi
    echo

    if [[ ${#SESSION_FILES[@]} -eq 0 ]]; then
        if [[ "$ALL_DIRS" == "1" ]]; then
            echo "  No sessions found."
        else
            echo "  No sessions in this directory. (-g lists every directory.)"
        fi
        echo
        return 0
    fi

    local i

    for i in "${!SESSION_FILES[@]}"; do
        local profile_index="${SESSION_PROFILE_INDEXES[$i]}"
        local profile="${PROFILE_NAMES[$profile_index]}"

        local cwd="${SESSION_CWDS[$i]}"
        local sid="${SESSION_IDS[$i]}"
        local title="${SESSION_TITLES[$i]}"
        local preview="${SESSION_PREVIEWS[$i]}"
        local time="${SESSION_TIMES[$i]}"

        local marker=" "

        # Only meaningful when other directories are listed too.
        if [[ "$ALL_DIRS" == "1" && -n "$cwd" && "$(realpath -m "$cwd")" == "$CURRENT_DIR" ]]; then
            marker="*"
        fi

        local running=""

        if [[ -n "${RUNNING_BY_SID[$sid]:-}" ]]; then
            running="  [running, pid ${RUNNING_BY_SID[$sid]}]"
        fi

        printf " %2d)%s %-12s %-13s %-11s %s%s\n" \
            "$((i + 1))" \
            "$marker" \
            "$profile" \
            "$(format_time "$time")" \
            "$(short_id "$sid")" \
            "$(pretty_path "$cwd")" \
            "$running"

        local summary="$title"

        if [[ -n "$title" && -n "$preview" ]]; then
            summary="$title — $preview"
        elif [[ -z "$title" ]]; then
            summary="$preview"
        fi

        if [[ -z "$summary" ]]; then
            if [[ "${SESSION_EMPTY[$i]:-0}" == "1" ]]; then
                summary="(empty)"
            else
                summary="(no typed prompt)"
            fi
        fi

        printf "      %s\n" "$(truncate_text "$summary" $((width - 7)))"

        echo
    done
}

# ============================================================
# Interactive selection helpers
# ============================================================

CHOSEN_PROFILE_INDEX=""

choose_profile() {
    local exclude_dir="${1:-}"
    local -a map=()

    echo
    echo "Claude accounts:"
    echo

    local n=1
    local i

    for i in "${!PROFILE_DIRS[@]}"; do
        if [[ -n "$exclude_dir" ]] &&
           [[ "$(realpath -m "${PROFILE_DIRS[$i]}")" == "$(realpath -m "$exclude_dir")" ]]; then
            continue
        fi

        printf "  %2d) %s\n" \
            "$n" \
            "${PROFILE_NAMES[$i]}"

        map+=("$i")
        n=$((n + 1))
    done

    if [[ ${#map[@]} -eq 0 ]]; then
        echo "No other Claude accounts are available."
        return 1
    fi

    echo

    local choice
    local prompt="Select account [1-${#map[@]}]: "

    # With only one account on offer, Enter picks it.
    if [[ ${#map[@]} -eq 1 ]]; then
        prompt="Select account [1, Enter = 1]: "
    fi

    while true; do
        read -rp "$prompt" choice

        if [[ -z "$choice" && ${#map[@]} -eq 1 ]]; then
            choice=1
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#map[@]} )); then

            CHOSEN_PROFILE_INDEX="${map[$((choice - 1))]}"
            return 0
        fi

        echo "Invalid selection."
    done
}

CHOSEN_SESSION_INDEX=""

choose_session() {
    if [[ ${#SESSION_FILES[@]} -eq 0 ]]; then
        if [[ "$ALL_DIRS" == "1" ]]; then
            echo "No Claude sessions found."
        else
            echo "No Claude sessions in this directory. Run with -g to see every directory."
        fi
        return 1
    fi

    echo

    local choice

    while true; do
        # Newest first, so Enter picks the most recent.
        read -rp "Select session [1-${#SESSION_FILES[@]}, Enter = 1]: " choice
        choice="${choice:-1}"

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#SESSION_FILES[@]} )); then

            CHOSEN_SESSION_INDEX=$((choice - 1))
            return 0
        fi

        echo "Invalid selection."
    done
}

# ============================================================
# Launch
# ============================================================

# launch_claude PROFILE_DIR CWD NAME [claude args...]
#
# NAME is the session's own name, or blank. With Remote Control on,
# a named session passes it as --remote-control NAME. A remote
# session belongs to one claude.ai login, so resuming under another
# account always creates a new one, and without this it would show
# up in the app under a generated name instead of yours.
launch_claude() {
    local profile_dir="$1"
    local cwd="$2"
    local name="$3"
    shift 3

    local -a extra=()

    if [[ "$REMOTE_CONTROL" == "1" ]]; then
        # A leading '-' would be read as an option, not as the name.
        if [[ -n "$name" && "$name" != -* ]]; then
            extra+=(--remote-control "$name")
        else
            extra+=(--settings '{"remoteControlAtStartup":true}')
        fi
    fi

    cd "$cwd"

    exec env \
        CLAUDE_CONFIG_DIR="$profile_dir" \
        claude "${extra[@]}" "$@" "${CLAUDE_ARGS[@]}"
}

# ============================================================
# Start fresh
# ============================================================

do_start() {
    local profile_index="$1"

    local profile_dir="${PROFILE_DIRS[$profile_index]}"
    local profile="${PROFILE_NAMES[$profile_index]}"

    check_running_claude \
        "$CURRENT_DIR" \
        "" \
        "$profile_dir" || return 1

    echo
    echo "Starting new Claude session"
    echo
    echo "  Account:   $profile"
    echo "  Directory: $(pretty_path "$CURRENT_DIR")"
    echo

    launch_claude "$profile_dir" "$CURRENT_DIR" ""
}

start_fresh() {
    choose_profile || return 1
    do_start "$CHOSEN_PROFILE_INDEX"
}

# ============================================================
# Resume session
# ============================================================

do_resume() {
    local i="$1"

    local profile_index="${SESSION_PROFILE_INDEXES[$i]}"
    local profile_dir="${PROFILE_DIRS[$profile_index]}"
    local profile="${PROFILE_NAMES[$profile_index]}"

    local sid="${SESSION_IDS[$i]}"
    local cwd="${SESSION_CWDS[$i]}"

    if [[ -z "$cwd" || ! -d "$cwd" ]]; then
        echo
        echo "WARNING: Original session directory is unavailable:"
        echo "  ${cwd:-unknown}"
        echo
        echo "Using the current directory instead:"
        echo "  $(pretty_path "$CURRENT_DIR")"
        echo
        echo "Claude looks sessions up by directory, so the resume"
        echo "may not find it from here."

        cwd="$CURRENT_DIR"
    fi

    check_running_claude \
        "$cwd" \
        "$sid" \
        "$profile_dir" || return 1

    echo
    echo "Resuming Claude session"
    echo
    echo "  Account:   $profile"
    echo "  Session:   $sid"

    if [[ -n "${SESSION_TITLES[$i]}" ]]; then
        echo "  Title:     ${SESSION_TITLES[$i]}"
    fi

    echo "  Directory: $(pretty_path "$cwd")"
    echo

    launch_claude "$profile_dir" "$cwd" "${SESSION_NAMES[$i]:-}" -r "$sid"
}


# Most recent session for the current directory, in any account
# (or only in ONLY_PROFILE_INDEX when given).
do_continue() {
    local only="${1:-}"
    local first=${#SESSION_FILES[@]}

    load_sessions 1 < <(
        current_dir_candidates \
            | awk -F'\t' -v only="$only" 'only == "" || $2 == only' \
            | sort -t $'\t' -k1,1nr
    )

    if (( ${#SESSION_FILES[@]} == first )); then
        die "No sessions found for $(pretty_path "$CURRENT_DIR")${only:+ in account '${PROFILE_NAMES[$only]}'}."
    fi

    do_resume "$first"
}

# ============================================================
# Locate same session ID in another profile
# ============================================================

find_destination_sessions() {
    local profile_dir="$1"
    local sid="$2"

    [[ -d "$profile_dir/projects" ]] || return 0

    find "$profile_dir/projects" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name "${sid}.jsonl" \
        -print \
        2>/dev/null \
        || true
}

# ============================================================
# Transfer session
#
# A session is more than its transcript. Everything below is
# keyed by the session ID, so no other session in the
# destination can be using it, and copying it is safe:
#
#   projects/<project>/<id>.jsonl    the transcript
#   projects/<project>/<id>/         subagent transcripts, tool results
#   file-history/<id>/               file snapshots that /rewind needs
#   session-env/<id>/                hook-set environment
#   tasks/<id>/                      task list
#   todos/<id>-*.json                todo lists (older versions)
#   plans/<slug>.md                  plan files the transcript names by slug
#
# Every destination item that would be replaced or removed is
# backed up first, under
#
#   <dst account>/session-transfer-backups/<id>/<timestamp>/
#
# with its path relative to the account kept, so restoring is a
# plain copy back.
#
# Two things are handled more carefully, because they are shared
# with other sessions:
#
#   projects/<project>/memory/   the project's auto memory; files
#                                missing in the destination are
#                                added, existing ones are never
#                                overwritten
#   history.jsonl                prompt history; not copied
#
# Deliberately never copied: .credentials.json, .claude.json and
# sessions/ (the live process registry), which belong to the
# account, not the session.
# ============================================================

# ------------------------------------------------------------
# archive_transcript PROFILE_DIR FILE STAMP
#
# Move a session's transcript out of Claude's view, to
#
#   <account>/session-transfer-backups/<id>/<STAMP>-archived/<path>
#
# where <path> is the transcript's path inside the account, so
# restoring it is moving it back. Only the transcript moves: the
# session directory, file history and so on stay, so absolute
# paths in the transcript keep resolving and a restored session
# is complete. Prints the new location.
# ------------------------------------------------------------

archive_transcript() {
    local profile_dir="$1"
    local file="$2"
    local stamp="$3"

    local sid
    sid="$(basename "$file" .jsonl)"

    local archived="$profile_dir/session-transfer-backups/$sid/$stamp-archived/$(relative_to "$file" "$profile_dir")"

    mkdir -p "$(dirname "$archived")"
    mv -- "$file" "$archived"

    printf '%s' "$archived"
}

# ============================================================
# Project memory sync
#
# projects/<project>/memory/ is shared by every session of the
# project in that account, so a transfer never simply replaces
# it. For each file in the source:
#
#   missing in the destination   copied
#   identical                    nothing to do
#   MEMORY.md (the index)        the newer copy, plus any index
#                                lines only the older copy has
#   anything else that differs   three-way merge against the
#                                version the last transfer synced;
#                                if both sides changed the same
#                                lines, you choose (or ask Claude)
#
# Files only the destination has are never touched. Before a
# destination file is changed it is backed up with the rest of
# the transfer's backups.
# ============================================================

# merge_memory_index NEWER OLDER MEMORY_DIR OUT
#
# The index is one line per memory, each linking to its file.
# Keep the newer index, drop lines whose file does not exist,
# and add the older index's lines for files the newer one does
# not mention, so no memory drops out of view.
merge_memory_index() {
    python3 - "$@" <<'PY'
import os
import re
import sys

newer, older, memory_dir, out = sys.argv[1:5]
LINK = re.compile(r"\]\(([^)#\s]+\.md)\)")


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def target(line):
    match = LINK.search(line)
    return match.group(1) if match else None


def exists(name):
    return os.path.isfile(os.path.join(memory_dir, name))


result = []
listed = set()

for line in read_lines(newer):
    name = target(line)

    if name and not exists(name):
        continue

    if name:
        listed.add(name)

    result.append(line)

for line in read_lines(older):
    name = target(line)

    if name and name not in listed and exists(name):
        result.append(line)
        listed.add(name)

with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(result) + "\n")
PY
}

# claude_merge_memory PROFILE_DIR NEWER_LABEL A_LABEL A B_LABEL B OUT
#
# Ask Claude for one note combining both versions. Runs from a
# scratch directory with no tools, no MCP servers and no saved
# session, so it cannot touch anything and leaves no transcript.
claude_merge_memory() {
    local profile_dir="$1"
    local newer_label="$2"
    local a_label="$3"
    local a="$4"
    local b_label="$5"
    local b="$6"
    local out="$7"

    local scratch
    scratch="$(mktemp -d)"

    local rc=0

    {
        cat <<EOF
Below are two versions of the same Claude Code memory note. Merge them into
one note that keeps every distinct fact, rule and example from both. Remove
repetition. Where they contradict each other, prefer the version from
"$newer_label", which is newer. Keep the note's format exactly, including any
frontmatter between --- lines. Output only the merged file content: no
commentary and no code fences.

===== VERSION FROM "$a_label" =====
EOF
        cat -- "$a"
        printf '\n===== VERSION FROM "%s" =====\n' "$b_label"
        cat -- "$b"
    } | (
        cd "$scratch" &&
        CLAUDE_CONFIG_DIR="$profile_dir" claude -p \
            --no-session-persistence \
            --tools "" \
            --strict-mcp-config
    ) > "$out" || rc=$?

    rm -rf -- "$scratch"

    # Some replies wrap the file in a code fence anyway.
    if (( rc == 0 )) && [[ -s "$out" ]]; then
        python3 - "$out" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read().strip("\n")
lines = text.splitlines()

if len(lines) >= 2 and lines[0].startswith("```") and lines[-1].strip() == "```":
    lines = lines[1:-1]

open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
        return 0
    fi

    rm -f -- "$out"
    return 1
}

# resolve_memory_conflict REL SRC DST OUT SRC_LABEL DST_LABEL DST_PROFILE_DIR
#
# Both sides changed the same lines. Sets MEMORY_CHOICE to src,
# dst or merged; for "merged" the result is in OUT.
MEMORY_CHOICE=""

resolve_memory_conflict() {
    local rel="$1"
    local src="$2"
    local dst="$3"
    local out="$4"
    local src_label="$5"
    local dst_label="$6"
    local dst_profile_dir="$7"

    local newer="src"
    local newer_label="$src_label"

    if [[ "$dst" -nt "$src" ]]; then
        newer="dst"
        newer_label="$dst_label"
    fi

    echo
    echo "  memory/$rel differs, and both sides changed it ($newer_label is newer)."

    local answer

    while true; do
        read -rp "  [Enter] keep newer, s = $src_label, d = $dst_label, v = view diff, c = merge with Claude: " answer

        case "$answer" in
            "")
                MEMORY_CHOICE="$newer"
                return 0
                ;;
            s|S)
                MEMORY_CHOICE="src"
                return 0
                ;;
            d|D)
                MEMORY_CHOICE="dst"
                return 0
                ;;
            v|V)
                echo
                diff -u --label "$dst_label" --label "$src_label" -- "$dst" "$src" || true
                echo
                ;;
            c|C)
                echo "  Asking Claude to merge..."

                if ! claude_merge_memory "$dst_profile_dir" "$newer_label" \
                        "$dst_label" "$dst" "$src_label" "$src" "$out"; then
                    echo "  The merge failed; choose another option."
                    continue
                fi

                echo
                diff -u --label "$dst_label (now)" --label "merged" -- "$dst" "$out" || true
                echo

                if confirm "  Use this merge?" y; then
                    MEMORY_CHOICE="merged"
                    return 0
                fi

                rm -f -- "$out"
                ;;
            *)
                echo "  Invalid selection."
                ;;
        esac
    done
}

# sync_memory SRC_MEMORY DST_MEMORY SRC_LABEL DST_LABEL DST_PROFILE_DIR BACKUP_DIR PROJECT_KEY
sync_memory() {
    local src_memory="$1"
    local dst_memory="$2"
    local src_label="$3"
    local dst_label="$4"
    local dst_profile_dir="$5"
    local backup_dir="$6"
    local project_key="$7"

    [[ -d "$src_memory" ]] || return 0

    local base_dir="$MEMORY_BASE_DIR/$project_key"

    # The index goes last, so it is merged against the final set
    # of memory files.
    local -a rels=()
    mapfile -t rels < <(
        find "$src_memory" -type f -printf '%P\n' 2>/dev/null \
            | sort \
            | awk '$0 == "MEMORY.md" { index_file = 1; next } { print } END { if (index_file) print "MEMORY.md" }'
    )

    local -a report=()
    local backed_up=0
    local rel

    for rel in "${rels[@]}"; do
        [[ -n "$rel" ]] || continue

        local src="$src_memory/$rel"
        local dst="$dst_memory/$rel"
        local base="$base_dir/$rel"
        local result="$dst.claudemulti-merge.$$"
        local line=""

        rm -f -- "$result"

        if ! path_exists "$dst"; then
            mkdir -p "$(dirname "$dst")"
            cp -a -- "$src" "$dst"
            line="added    memory/$rel"

        elif cmp -s "$src" "$dst"; then
            line=""

        elif [[ "$rel" == "MEMORY.md" ]]; then
            if [[ "$dst" -nt "$src" ]]; then
                merge_memory_index "$dst" "$src" "$dst_memory" "$result"
            else
                merge_memory_index "$src" "$dst" "$dst_memory" "$result"
            fi
            line="merged   memory/$rel  (index lines from both)"

        elif [[ -f "$base" ]] && git merge-file -p -- "$dst" "$base" "$src" > "$result" 2>/dev/null; then
            line="merged   memory/$rel  (changes from both)"

        else
            rm -f -- "$result"

            resolve_memory_conflict "$rel" "$src" "$dst" "$result" \
                "$src_label" "$dst_label" "$dst_profile_dir"

            case "$MEMORY_CHOICE" in
                src)
                    cp -- "$src" "$result"
                    line="updated  memory/$rel  (took $src_label's)"
                    ;;
                dst)
                    line="kept     memory/$rel  ($dst_label's)"
                    ;;
                merged)
                    line="merged   memory/$rel  (by Claude)"
                    ;;
            esac
        fi

        # Swap a changed result in, backing up what it replaces.
        if [[ -f "$result" ]]; then
            if cmp -s "$result" "$dst"; then
                rm -f -- "$result"
            else
                local backup="$backup_dir/$(relative_to "$dst" "$dst_profile_dir")"

                mkdir -p "$(dirname "$backup")"
                cp -a -- "$dst" "$backup"
                backed_up=1

                mv -f -- "$result" "$dst"
            fi
        fi

        # The source's version is what both sides now share: the
        # destination holds it or has merged it in. It is the
        # right ancestor for the next merge in either direction.
        mkdir -p "$(dirname "$base")"
        cp -- "$src" "$base"

        if [[ -n "$line" ]]; then
            report+=("$line")
        fi
    done

    if [[ ${#report[@]} -gt 0 ]]; then
        echo
        echo "Project memory:"

        for line in "${report[@]}"; do
            echo "  $line"
        done

        if (( backed_up )); then
            echo
            echo "  Previous destination copies backed up to:"
            echo "    $(pretty_path "$backup_dir")"
        fi
    fi
}

declare -a XFER_SRC=()
declare -a XFER_DST=()

add_transfer_item() {
    XFER_SRC+=("$1")
    XFER_DST+=("$2")
}

# Same type and same content, compared without following links.
items_identical() {
    local a="$1"
    local b="$2"

    path_exists "$a" && path_exists "$b" || return 1

    if [[ -d "$a" && ! -L "$a" ]]; then
        [[ -d "$b" && ! -L "$b" ]] || return 1
    else
        [[ ! -d "$b" || -L "$b" ]] || return 1
    fi

    diff -rq --no-dereference -- "$a" "$b" >/dev/null 2>&1
}

# Copy next to the destination first, then swap it in, so a
# failed copy never leaves the destination half-written. The
# temporary name does not end in .jsonl, so Claude never lists
# it as a session.
replace_item() {
    local src="$1"
    local dst="$2"
    local tmp="$dst.claudemulti-tmp.$$"

    mkdir -p "$(dirname "$dst")"
    rm -rf -- "$tmp"
    cp -a -- "$src" "$tmp"

    if [[ -d "$dst" && ! -L "$dst" ]]; then
        rm -rf -- "$dst"
    fi

    mv -fT -- "$tmp" "$dst"
}

relative_to() {
    local path="$1"
    local base="$2"

    printf '%s' "${path#"$base"/}"
}

do_transfer() {
    local i="$1"
    local dst_profile_index="$2"

    local src_profile_index="${SESSION_PROFILE_INDEXES[$i]}"
    local src_profile_dir="${PROFILE_DIRS[$src_profile_index]}"
    local src_profile="${PROFILE_NAMES[$src_profile_index]}"

    local dst_profile_dir="${PROFILE_DIRS[$dst_profile_index]}"
    local dst_profile="${PROFILE_NAMES[$dst_profile_index]}"

    local src_file="${SESSION_FILES[$i]}"
    local sid="${SESSION_IDS[$i]}"
    local cwd="${SESSION_CWDS[$i]}"

    echo
    echo "Selected session:"
    echo
    echo "  Account:   $src_profile"
    echo "  Session:   $sid"

    if [[ -n "${SESSION_TITLES[$i]}" ]]; then
        echo "  Title:     ${SESSION_TITLES[$i]}"
    fi

    echo "  Directory: $(pretty_path "$cwd")"

    if [[ "$src_profile_index" == "$dst_profile_index" ]]; then
        echo
        echo "The session is already in '$dst_profile'. Resuming it there."
        do_resume "$i"
        return
    fi

    # --------------------------------------------------------
    # Running-session safety check. Copying a transcript while
    # a turn is in flight captures a tool call with no result.
    # --------------------------------------------------------

    local effective_cwd="$cwd"

    if [[ -z "$effective_cwd" || ! -d "$effective_cwd" ]]; then
        effective_cwd="$CURRENT_DIR"
    fi

    check_running_claude \
        "$effective_cwd" \
        "$sid" \
        "$dst_profile_dir" || return 1

    # --------------------------------------------------------
    # Determine destination transcript
    # --------------------------------------------------------

    local relative_path
    relative_path="$(relative_to "$src_file" "$src_profile_dir")"

    local default_dst_file="$dst_profile_dir/$relative_path"

    local -a existing=()

    mapfile -t existing < <(
        find_destination_sessions \
            "$dst_profile_dir" \
            "$sid"
    )

    local dst_file

    if [[ ${#existing[@]} -eq 0 ]]; then
        dst_file="$default_dst_file"

    elif [[ ${#existing[@]} -eq 1 ]]; then
        dst_file="${existing[0]}"

    elif [[ -f "$default_dst_file" ]]; then
        dst_file="$default_dst_file"

    else
        echo
        echo "ERROR: Multiple copies of this session exist in '$dst_profile':"
        echo

        local file

        for file in "${existing[@]}"; do
            echo "  $file"
        done

        echo
        echo "Refusing to guess which copy should be replaced."
        return 1
    fi

    local src_project_dir
    local dst_project_dir

    src_project_dir="$(dirname "$src_file")"
    dst_project_dir="$(dirname "$dst_file")"

    # --------------------------------------------------------
    # Never roll a conversation backward silently.
    # --------------------------------------------------------

    if [[ -f "$dst_file" ]] && ! cmp -s "$src_file" "$dst_file"; then
        local src_mtime
        local dst_mtime

        src_mtime="$(stat -c '%Y' "$src_file")"
        dst_mtime="$(stat -c '%Y' "$dst_file")"

        echo
        echo "A different copy of this session exists in '$dst_profile'."
        echo
        echo "  Source:      $(format_time "$src_mtime")"
        echo "  Destination: $(format_time "$dst_mtime")"
        echo

        if (( dst_mtime > src_mtime )); then
            echo "WARNING:"
            echo "The destination copy is NEWER than the source."
            echo
            echo "Replacing it could roll the conversation backward."
            echo "(It will be backed up either way.)"
            echo

            if ! confirm "Replace the newer destination copy?"; then
                echo
                echo "Transfer cancelled."
                return 1
            fi
        else
            echo "The destination copy is older and will be replaced."
        fi
    fi

    # --------------------------------------------------------
    # Build the list of per-session items. The transcript goes
    # LAST: it is what makes the session visible, so it lands
    # only once everything it refers to is in place.
    # --------------------------------------------------------

    XFER_SRC=()
    XFER_DST=()

    add_transfer_item "$src_project_dir/$sid" "$dst_project_dir/$sid"

    local state

    for state in file-history session-env tasks; do
        add_transfer_item "$src_profile_dir/$state/$sid" "$dst_profile_dir/$state/$sid"
    done

    local name

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        add_transfer_item "$src_profile_dir/todos/$name" "$dst_profile_dir/todos/$name"
    done < <(
        {
            find "$src_profile_dir/todos" "$dst_profile_dir/todos" \
                -maxdepth 1 \
                -type f \
                -name "$sid-*.json" \
                -printf '%f\n' \
                2>/dev/null \
                || true
        } | sort -u
    )

    # Plans are named by a slug, not by the session ID, so only
    # the ones this transcript names are copied, and a
    # destination plan is never removed.
    local slug

    while IFS= read -r slug; do
        [[ "$slug" =~ ^[A-Za-z0-9._-]+$ && "$slug" != .* ]] || continue

        if [[ -f "$src_profile_dir/plans/$slug.md" ]]; then
            add_transfer_item "$src_profile_dir/plans/$slug.md" "$dst_profile_dir/plans/$slug.md"
        fi
    done < <(
        grep -o '"slug":"[^"]*"' "$src_file" 2>/dev/null \
            | sed 's/^"slug":"//; s/"$//' \
            | sort -u \
            || true
    )

    add_transfer_item "$src_file" "$dst_file"

    # --------------------------------------------------------
    # Decide what happens to each item.
    # --------------------------------------------------------

    local -a actions=()
    local need_backup=0
    local k

    for k in "${!XFER_SRC[@]}"; do
        local src="${XFER_SRC[$k]}"
        local dst="${XFER_DST[$k]}"
        local action="skip"

        if path_exists "$src"; then
            if ! path_exists "$dst"; then
                action="copy"
            elif items_identical "$src" "$dst"; then
                action="same"
            else
                action="replace"
                need_backup=1
            fi
        elif path_exists "$dst"; then
            # Left over from an earlier copy of this session;
            # it would not match the transcript being installed.
            action="remove"
            need_backup=1
        fi

        actions+=("$action")
    done

    echo
    echo "Transfer plan ($src_profile → $dst_profile):"
    echo

    for k in "${!XFER_SRC[@]}"; do
        [[ "${actions[$k]}" != "skip" ]] || continue

        printf "  %-8s %s\n" \
            "${actions[$k]}" \
            "$(relative_to "${XFER_DST[$k]}" "$dst_profile_dir")"
    done

    # --------------------------------------------------------
    # Back up everything that will be replaced or removed,
    # before touching anything.
    # --------------------------------------------------------

    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"

    if (( need_backup )); then
        local backup_dir="$dst_profile_dir/session-transfer-backups/$sid/$timestamp"

        for k in "${!XFER_SRC[@]}"; do
            case "${actions[$k]}" in
                replace|remove) ;;
                *) continue ;;
            esac

            local dst="${XFER_DST[$k]}"
            local backup="$backup_dir/$(relative_to "$dst" "$dst_profile_dir")"

            mkdir -p "$(dirname "$backup")"
            cp -a -- "$dst" "$backup"
        done

        echo
        echo "Destination items backed up:"
        echo "  $(pretty_path "$backup_dir")"
    fi

    # --------------------------------------------------------
    # Apply.
    # --------------------------------------------------------

    for k in "${!XFER_SRC[@]}"; do
        case "${actions[$k]}" in
            copy|replace)
                replace_item "${XFER_SRC[$k]}" "${XFER_DST[$k]}"
                ;;
            remove)
                rm -rf -- "${XFER_DST[$k]}"
                ;;
        esac
    done

    # --------------------------------------------------------
    # Project memory: add what is missing, merge what differs.
    # --------------------------------------------------------

    sync_memory \
        "$src_project_dir/memory" \
        "$dst_project_dir/memory" \
        "$src_profile" \
        "$dst_profile" \
        "$dst_profile_dir" \
        "$dst_profile_dir/session-transfer-backups/$sid/$timestamp" \
        "$(basename "$src_project_dir")"

    local changed=0

    for k in "${!actions[@]}"; do
        case "${actions[$k]}" in
            copy|replace|remove) changed=1 ;;
        esac
    done

    echo

    if (( changed )); then
        echo "Session transferred successfully."
    else
        echo "The destination was already up to date; nothing copied."
    fi

    echo
    echo "  From:    $src_profile"
    echo "  To:      $dst_profile"
    echo "  Session: $sid"
    echo

    # --------------------------------------------------------
    # Optionally retire the source copy, so that resuming it
    # there by mistake cannot fork the conversation. Only the
    # transcript moves: the source session directory stays, so
    # absolute paths in the transcript that point at it (tool
    # results, for instance) keep resolving.
    # --------------------------------------------------------

    if confirm "Archive the source copy so only '$dst_profile' lists this session?" y; then
        local archived
        archived="$(archive_transcript "$src_profile_dir" "$src_file" "$timestamp")"

        echo
        echo "Source transcript archived:"
        echo "  $(pretty_path "$archived")"
    fi

    # --------------------------------------------------------
    # Immediately resume using destination account
    # --------------------------------------------------------

    echo
    echo "Starting Claude under '$dst_profile'..."
    echo

    launch_claude "$dst_profile_dir" "$effective_cwd" "${SESSION_NAMES[$i]:-}" -r "$sid"
}


# ============================================================
# Accounts overview
# ============================================================

show_accounts() {
    discover_running

    echo
    echo "Claude accounts"
    echo "════════════════════════════════════════════════════════════════"
    echo

    local i

    for i in "${!PROFILE_DIRS[@]}"; do
        local dir="${PROFILE_DIRS[$i]}"
        local count=0
        local running=0
        local k

        if [[ -d "$dir/projects" ]]; then
            count="$(
                find "$dir/projects" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null \
                    | grep -cE '/[0-9a-fA-F-]{20,}\.jsonl$' || true
            )"
        fi

        for k in "${!RUN_PIDS[@]}"; do
            if [[ "${RUN_CONFIGS[$k]}" == "$dir" ]]; then
                running=$((running + 1))
            fi
        done

        printf "  %-12s %4s sessions  %2s running   %s\n" \
            "${PROFILE_NAMES[$i]}" \
            "$count" \
            "$running" \
            "$(pretty_path "$dir")"
    done

    echo
}

# ============================================================
# Interactive menu
# ============================================================

# ------------------------------------------------------------
# do_archive SESSION_INDEX
#
# Hide an old session from Claude and from this list. Refuses
# while the session is running: Claude would recreate the
# transcript on its next write, leaving a partial copy behind.
# ------------------------------------------------------------

do_archive() {
    local i="$1"

    local profile_index="${SESSION_PROFILE_INDEXES[$i]}"
    local profile_dir="${PROFILE_DIRS[$profile_index]}"
    local file="${SESSION_FILES[$i]}"
    local sid="${SESSION_IDS[$i]}"

    discover_running

    if [[ -n "${RUNNING_BY_SID[$sid]:-}" ]]; then
        echo
        echo "This session is running (pid ${RUNNING_BY_SID[$sid]}). Exit it first."
        return 1
    fi

    echo
    confirm "Archive this session?" y || return 1

    local archived
    archived="$(archive_transcript "$profile_dir" "$file" "$(date '+%Y%m%d-%H%M%S')")"

    echo
    echo "Archived to:"
    echo "  $(pretty_path "$archived")"
    echo
    echo "To restore it, move that file back to:"
    echo "  $(pretty_path "$file")"
}

# ------------------------------------------------------------
# Second step of the menu: what to do with the chosen session.
# Resume is first and is what Enter does.
#
# Returns 1 for "back", an archive, or a cancelled action; resume
# and transfer exec claude and never return.
# ------------------------------------------------------------

session_actions() {
    local i="$1"

    local profile_index="${SESSION_PROFILE_INDEXES[$i]}"

    echo
    echo "Session ${SESSION_IDS[$i]}"
    echo
    echo "  Account:   ${PROFILE_NAMES[$profile_index]}"

    if [[ -n "${SESSION_TITLES[$i]}" ]]; then
        echo "  Title:     ${SESSION_TITLES[$i]}"
    fi

    echo "  Directory: $(pretty_path "${SESSION_CWDS[$i]}")"
    echo
    echo "  1) Resume"
    echo "  2) Transfer to another account and resume there"
    echo "  3) Archive"
    echo "  4) Back"
    echo

    local action

    while true; do
        read -rp "Select action [1-4, Enter = resume]: " action

        case "$action" in
            ""|1|r|R)
                do_resume "$i"
                return
                ;;
            2|t|T)
                choose_profile "${PROFILE_DIRS[$profile_index]}" || return 1
                do_transfer "$i" "$CHOSEN_PROFILE_INDEX"
                return
                ;;
            3|a|A)
                # Back to the (reloaded) session list either way.
                do_archive "$i" || true
                return 1
                ;;
            4|b|B)
                return 1
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}

interactive_menu() {
    clear 2>/dev/null || true

    echo
    echo "ClaudeMulti"
    echo "════════════════════════════════════════════════════════════════"

    local choice

    while true; do
        discover_sessions

        if [[ "$ALL_DIRS" == "1" ]]; then
            echo
            echo "Current directory:"
            echo "  $(pretty_path "$CURRENT_DIR")"
        fi

        show_sessions

        local count=${#SESSION_FILES[@]}
        local scope_hint="g = all directories"

        if [[ "$ALL_DIRS" == "1" ]]; then
            scope_hint="g = this directory only"
        fi

        local prompt="n = new session, $scope_hint, q = quit: "

        if (( count > 0 )); then
            # The list is newest first, so 1 is the most recent.
            prompt="Select session [1-$count, Enter = 1], $prompt"
        fi

        while true; do
            read -rp "$prompt" choice

            if [[ -z "$choice" ]] && (( count > 0 )); then
                choice=1
            fi

            case "$choice" in
                n|N)
                    start_fresh || true
                    echo
                    continue
                    ;;
                g|G)
                    if [[ "$ALL_DIRS" == "1" ]]; then
                        ALL_DIRS=0
                    else
                        ALL_DIRS=1
                    fi
                    break
                    ;;
                q|Q)
                    exit 0
                    ;;
            esac

            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
                # Back or cancelled: list the sessions again.
                session_actions $((choice - 1)) || true
                break
            fi

            echo "Invalid selection."
        done
    done
}

# ============================================================
# Command line
# ============================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [-- claude arguments...]

With no options, shows the interactive menu.

  -a, --account NAME     Start a fresh session under NAME in the current
                         directory. With -r or -c, only look in NAME.
                         With -t, NAME is the destination.
  -r, --resume [SESSION] Resume SESSION under the account that has it.
                         Without SESSION, pick from the list.
  -c, --continue         Resume the most recent session for the current
                         directory, whichever account it is in.
  -t, --transfer SESSION Copy SESSION to the account given with -a
                         (asked for if omitted) and resume it there.
  -l, --list             List this directory's sessions and exit.
  -g, --global           List sessions from every directory, not just the
                         current one (list, menu and -r picker).
      --all              Include empty sessions (opened and closed without
                         a prompt) in the list and the menu.
  -p, --ps               List running Claude instances and exit.
      --accounts         List accounts and exit.
  -h, --help             Show this help.

SESSION is a number from --list (with -g if you listed with -g),
or a session ID or ID prefix (at least 4 characters) from any
directory.

Arguments after -- are passed to claude, e.g.

  $(basename "$0") -a work -- --model opus

Environment: CLAUDE_PROFILES_BASE (default ~/.claude-accounts),
CLAUDEMULTI_LIMIT (default 30), CLAUDEMULTI_INCLUDE_DEFAULT=1,
CLAUDEMULTI_REMOTE_CONTROL (default 1; 0 leaves it to the account).
EOF
}

MODE=""
ARG_ACCOUNT=""
ARG_SESSION=""

set_mode() {
    if [[ -n "$MODE" && "$MODE" != "$1" ]]; then
        die "Options for '$MODE' and '$1' cannot be combined (see --help)."
    fi

    MODE="$1"
}

while (( $# )); do
    case "$1" in
        -a|--account)
            [[ $# -ge 2 && "$2" != -* ]] || die "$1 needs an account name."
            ARG_ACCOUNT="$2"
            shift 2
            ;;
        --account=*)
            ARG_ACCOUNT="${1#--account=}"
            shift
            ;;
        -r|--resume)
            set_mode resume
            if [[ $# -ge 2 && "$2" != -* ]]; then
                ARG_SESSION="$2"
                shift
            fi
            shift
            ;;
        --resume=*)
            set_mode resume
            ARG_SESSION="${1#--resume=}"
            shift
            ;;
        -c|--continue)
            set_mode continue
            shift
            ;;
        -t|--transfer)
            set_mode transfer
            [[ $# -ge 2 && "$2" != -* ]] || die "$1 needs a session."
            ARG_SESSION="$2"
            shift 2
            ;;
        --transfer=*)
            set_mode transfer
            ARG_SESSION="${1#--transfer=}"
            shift
            ;;
        -l|--list)
            set_mode list
            shift
            ;;
        -p|--ps)
            set_mode ps
            shift
            ;;
        --accounts)
            set_mode accounts
            shift
            ;;
        --all)
            SHOW_EMPTY=1
            shift
            ;;
        -g|--global)
            ALL_DIRS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            CLAUDE_ARGS=("$@")
            break
            ;;
        *)
            die "Unknown option: $1 (see --help)"
            ;;
    esac
done

if [[ -z "$MODE" && -n "$ARG_ACCOUNT" ]]; then
    MODE="fresh"
fi

# ============================================================
# Main
# ============================================================

command -v claude >/dev/null 2>&1 \
    || die "'claude' is not in PATH"

command -v python3 >/dev/null 2>&1 \
    || die "python3 is required"

command -v realpath >/dev/null 2>&1 \
    || die "realpath is required"

discover_profiles

ACCOUNT_INDEX=""

if [[ -n "$ARG_ACCOUNT" ]]; then
    resolve_account "$ARG_ACCOUNT"
    ACCOUNT_INDEX="$RESOLVED_PROFILE_INDEX"
fi

case "$MODE" in
    "")
        interactive_menu
        ;;

    fresh)
        do_start "$ACCOUNT_INDEX" || exit 1
        ;;

    resume)
        if [[ -z "$ARG_SESSION" ]]; then
            discover_sessions
            show_sessions
            choose_session || exit 1
            do_resume "$CHOSEN_SESSION_INDEX" || exit 1
        else
            resolve_session "$ARG_SESSION" "$ACCOUNT_INDEX"
            do_resume "$RESOLVED_SESSION_INDEX" || exit 1
        fi
        ;;

    continue)
        do_continue "$ACCOUNT_INDEX" || exit 1
        ;;

    transfer)
        # The source is any account except the destination; if
        # the session only exists in the destination, use that.
        if [[ -n "$ACCOUNT_INDEX" && ! "$ARG_SESSION" =~ ^[0-9]{1,3}$ ]]; then
            if [[ -n "$(session_candidates | awk -F'\t' -v p="$ARG_SESSION" -v d="$ACCOUNT_INDEX" '
                    { n = $3; sub(/.*\//, "", n) }
                    index(n, p) == 1 && $2 != d { print; exit }')" ]]; then
                resolve_session "$ARG_SESSION" "" "$ACCOUNT_INDEX"
            else
                resolve_session "$ARG_SESSION" "$ACCOUNT_INDEX"
            fi
        else
            resolve_session "$ARG_SESSION"
        fi

        session_index="$RESOLVED_SESSION_INDEX"

        if [[ -z "$ACCOUNT_INDEX" ]]; then
            choose_profile "${PROFILE_DIRS[${SESSION_PROFILE_INDEXES[$session_index]}]}" || exit 1
            ACCOUNT_INDEX="$CHOSEN_PROFILE_INDEX"
        fi

        do_transfer "$session_index" "$ACCOUNT_INDEX" || exit 1
        ;;

    list)
        if [[ -n "$ACCOUNT_INDEX" ]]; then
            die "--list shows every account; -a is not used with it."
        fi
        discover_sessions
        show_sessions
        ;;

    ps)
        show_running
        ;;

    accounts)
        show_accounts
        ;;
esac
