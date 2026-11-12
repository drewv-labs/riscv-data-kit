#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Persistent VT100 Bottom Progress Bar (APT-Fancy Style)
# Path: riscv-data-kit/lib/progbar.sh
#
# Modes:
#   1. Standalone Mode (default):
#      Reserves 1 row at the bottom of the terminal (row = ROWS), confines
#      scrolling logs to [1 .. ROWS-1] via DECSTBM (\033[1;<end>r), and restores
#      the full terminal scroll region on EXIT/INT/TERM.
#   2. Stacked Sub-Process Mode (BRAKERRAK_PROGBAR_ACTIVE=1):
#      Draws RVDK sub-module progress on row (ROWS - 1) directly above the
#      BrakerRak master progress bar on row (ROWS), keeping scroll margins at
#      [1 .. ROWS-2] without tearing down BrakerRak's dock on sub-process exit.
#   3. Suppressed Mode (--noprogbar | RVDK_NO_PROGBAR=1 | non-TTY | dumb term):
#      All functions become zero-overhead no-ops.
# ==============================================================================

# Guard against double-sourcing within the same shell process
if [[ "${_RVDK_PROGBAR_SOURCED:-0}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_RVDK_PROGBAR_SOURCED="1"

# Literal ESC byte (0x1B). Never pass `\0337` through `printf "%b"`, because
# bash parses `\0` + 3 octal digits (`\0337` -> 0xDF) instead of ESC + '7'!
_RVDK_ESC=$'\033'

_RVDK_PROG_ACTIVE="0"
_RVDK_PROG_MODE="off"       # off | standalone | stacked
_RVDK_PROG_OWNER="0"        # 1 if this shell owns DECSTBM teardown on EXIT
_RVDK_PROG_ROWS=0
_RVDK_PROG_COLS=0
_RVDK_PROG_PCT=0
_RVDK_PROG_MSG=""

_RVDK_FILL_TEMPLATE="########################################"
_RVDK_DOTS_TEMPLATE="........................................"

_rvdk_prog_out() {
    if [[ -t 1 ]]; then
        printf '%s' "$1" 2>/dev/null || true
    fi
    return 0
}

_rvdk_prog_query_geom() {
    local sz="" r="" c=""
    sz="$(stty size <&1 2>/dev/null || stty size < /dev/tty 2>/dev/null || stty size <&2 2>/dev/null || true)"
    if [[ -n "$sz" ]]; then
        r="${sz%% *}"
        c="${sz##* }"
    fi
    if [[ ! "$r" =~ ^[0-9]+$ ]] || (( r <= 0 )); then
        r="$(tput lines 2>/dev/null || echo "${LINES:-24}")"
    fi
    if [[ ! "$c" =~ ^[0-9]+$ ]] || (( c <= 0 )); then
        c="$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")"
    fi
    [[ "$r" =~ ^[0-9]+$ ]] || r=24
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    _RVDK_PROG_ROWS="$r"
    _RVDK_PROG_COLS="$c"
    return 0
}

# Format a single progress bar row (strictly <= COLS - 1 visible chars)
# Usage: _rvdk_prog_format_line <badge_label> <badge_ansi> <bar_ansi> <pct> <msg> <cols>
_rvdk_prog_format_line() {
    local label="$1"
    local badge_ansi="$2"
    local bar_ansi="$3"
    local pct="$4"
    local msg="$5"
    local cols="$6"
    local esc="$_RVDK_ESC"

    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100

    local max_vis=$(( cols - 1 ))
    if (( max_vis < 24 )); then
        printf ''
        return 0
    fi

    # Fixed 18-char badge (" %-9s [%3d%%] ") so RVDK & BrakerRak align vertically
    local badge_txt
    badge_txt="$(printf " %-9s [%3d%%] " "$label" "$pct")"

    local bar_w=$(( cols / 4 ))
    (( bar_w < 10 )) && bar_w=10
    (( bar_w > 36 )) && bar_w=36

    # Ensure badge (18) + "[" (1) + bar_w + "]" (1) + 1 = 21 + bar_w fits within max_vis
    if (( 18 + bar_w + 3 > max_vis )); then
        bar_w=$(( max_vis - 21 ))
        (( bar_w < 4 )) && bar_w=4
    fi

    local filled=$(( pct * bar_w / 100 ))
    local empty=$(( bar_w - filled ))
    local hashes="${_RVDK_FILL_TEMPLATE:0:$filled}"
    local dots="${_RVDK_DOTS_TEMPLATE:0:$empty}"

    # Sanitize single-line message and clamp to remaining columns
    msg="${msg//$'\r'/}"
    msg="${msg//$'\n'/ }"
    msg="${msg//"$esc"/}"
    local msg_budget=$(( max_vis - 18 - bar_w - 3 - 1 ))
    local msg_part=""
    if (( msg_budget >= 4 )) && [[ -n "$msg" ]]; then
        if (( ${#msg} > msg_budget )); then
            msg_part=" ${msg:0:$(( msg_budget - 3 ))}..."
        else
            msg_part=" ${msg}"
        fi
    fi

    printf '%s%s%s[0m[%s%s%s[0m%s[2m%s%s[0m]%s' \
        "$badge_ansi" "$badge_txt" "$esc" \
        "$bar_ansi" "$hashes" "$esc" \
        "$esc" "$dots" "$esc" \
        "$msg_part"
    return 0
}

_rvdk_prog_render() {
    [[ "$_RVDK_PROG_ACTIVE" != "1" ]] && return 0

    local esc="$_RVDK_ESC"
    local prev_rows="$_RVDK_PROG_ROWS"
    _rvdk_prog_query_geom
    local rows="$_RVDK_PROG_ROWS"
    local cols="$_RVDK_PROG_COLS"
    (( rows < 10 || cols < 40 )) && return 0

    local rvdk_line
    rvdk_line="$(_rvdk_prog_format_line "RVDK" "${esc}[46;30;1m" "${esc}[1;36m" "$_RVDK_PROG_PCT" "$_RVDK_PROG_MSG" "$cols")"

    if [[ "$_RVDK_PROG_MODE" == "stacked" ]]; then
        local scroll_end=$(( rows - 2 ))
        local sub_row=$(( rows - 1 ))
        local master_row="$rows"
        local seq="${esc}7${esc}[1;${scroll_end}r"

        if (( prev_rows > 0 && prev_rows != rows )); then
            local old_sub=$(( prev_rows - 1 ))
            if (( old_sub >= 1 && old_sub <= rows )); then
                seq+="${esc}[${old_sub};1H${esc}[0K"
            fi
            if (( prev_rows >= 1 && prev_rows <= rows )); then
                seq+="${esc}[${prev_rows};1H${esc}[0K"
            fi
        fi

        seq+="${esc}[${sub_row};1H${rvdk_line}${esc}[0K"

        # Self-heal BrakerRak master bar on row=ROWS if state file is present
        if [[ -n "${BRAKERRAK_MASTER_STATE:-}" && -r "${BRAKERRAK_MASTER_STATE}" ]]; then
            local m_raw="" m_pct="0" m_msg="" m_line=""
            IFS= read -r m_raw < "${BRAKERRAK_MASTER_STATE}" 2>/dev/null || true
            if [[ -n "$m_raw" ]]; then
                m_pct="${m_raw%%|*}"
                m_msg="${m_raw#*|}"
                [[ "$m_pct" =~ ^[0-9]+$ ]] || m_pct=0
                m_line="$(_rvdk_prog_format_line "BrakerRak" "${esc}[45;37;1m" "${esc}[1;35m" "$m_pct" "$m_msg" "$cols")"
                seq+="${esc}[${master_row};1H${m_line}${esc}[0K"
            fi
        fi

        seq+="${esc}8"
        if (( prev_rows > 0 && prev_rows > rows )); then
            seq+="${esc}[${scroll_end};1H"
        fi
        _rvdk_prog_out "$seq"
    else
        local scroll_end=$(( rows - 1 ))
        local bar_row="$rows"
        local seq="${esc}7${esc}[1;${scroll_end}r"
        if (( prev_rows > 0 && prev_rows != rows && prev_rows <= rows )); then
            seq+="${esc}[${prev_rows};1H${esc}[0K"
        fi
        seq+="${esc}[${bar_row};1H${rvdk_line}${esc}[0K${esc}8"
        if (( prev_rows > 0 && prev_rows > rows )); then
            seq+="${esc}[${scroll_end};1H"
        fi
        _rvdk_prog_out "$seq"
    fi
    return 0
}

rvdk_prog_init() {
    local init_label="${1:-Initializing...}"
    local esc="$_RVDK_ESC"

    if [[ "${RVDK_NO_PROGBAR:-0}" == "1" || "${NO_PROGBAR:-0}" == "1" ]]; then
        return 0
    fi
    if [[ ! -t 1 || "${TERM:-dumb}" == "dumb" ]]; then
        return 0
    fi

    _rvdk_prog_query_geom
    if (( _RVDK_PROG_ROWS < 10 || _RVDK_PROG_COLS < 40 )); then
        return 0
    fi

    _RVDK_PROG_ACTIVE="1"
    _RVDK_PROG_PCT="${RVDK_PROG_BASE:-0}"
    _RVDK_PROG_MSG="$init_label"

    if [[ "${BRAKERRAK_PROGBAR_ACTIVE:-0}" == "1" ]]; then
        # Stacked above BrakerRak master bar: BrakerRak already reserved 2 rows
        _RVDK_PROG_MODE="stacked"
        _RVDK_PROG_OWNER="0"
        trap '_rvdk_prog_render' WINCH
        if [[ -n "${BRAKERRAK_SUB_STATE:-}" ]]; then
            printf '%s|%s\n' "$_RVDK_PROG_PCT" "$_RVDK_PROG_MSG" > "${BRAKERRAK_SUB_STATE}" 2>/dev/null || true
        fi
        _rvdk_prog_render
    elif [[ "${RVDK_PROGBAR_SESSION:-0}" == "1" ]]; then
        # Child script inside an already-initialized standalone `rvdk` session
        _RVDK_PROG_MODE="standalone"
        _RVDK_PROG_OWNER="0"
        trap '_rvdk_prog_render' WINCH
        _rvdk_prog_render
    else
        # Top-level standalone `rvdk` (or direct module invocation): reserve 1 bottom row.
        # Advance 1 line and step up 1 row BEFORE saving cursor so DECSC is guaranteed
        # to lie within [1 .. scroll_end] prior to activating DECSTBM.
        _RVDK_PROG_MODE="standalone"
        _RVDK_PROG_OWNER="1"
        export RVDK_PROGBAR_SESSION="1"
        local scroll_end=$(( _RVDK_PROG_ROWS - 1 ))
        _rvdk_prog_out $'\n'"${esc}[1A${esc}7${esc}[1;${scroll_end}r${esc}8"
        trap 'rvdk_prog_cleanup' EXIT
        trap 'rvdk_prog_cleanup; trap - INT; kill -INT $$' INT
        trap 'rvdk_prog_cleanup; trap - TERM; kill -TERM $$' TERM
        trap '_rvdk_prog_render' WINCH
        _rvdk_prog_render
    fi
    return 0
}

# Update RVDK progress bar (scales 0..100 into [RVDK_PROG_BASE .. +RVDK_PROG_SPAN])
# Usage: rvdk_prog <pct_0_to_100> <status_message>
rvdk_prog() {
    [[ "$_RVDK_PROG_ACTIVE" != "1" ]] && return 0
    local raw_pct="${1:-0}"
    local msg="${2:-}"
    [[ "$raw_pct" =~ ^[0-9]+$ ]] || raw_pct=0
    (( raw_pct < 0 )) && raw_pct=0
    (( raw_pct > 100 )) && raw_pct=100

    local base="${RVDK_PROG_BASE:-0}"
    local span="${RVDK_PROG_SPAN:-100}"
    [[ "$base" =~ ^[0-9]+$ ]] || base=0
    [[ "$span" =~ ^[0-9]+$ ]] || span=100

    local scaled=$(( base + (raw_pct * span) / 100 ))
    (( scaled < 0 )) && scaled=0
    (( scaled > 100 )) && scaled=100

    _RVDK_PROG_PCT="$scaled"
    [[ -n "$msg" ]] && _RVDK_PROG_MSG="$msg"

    if [[ "$_RVDK_PROG_MODE" == "stacked" && -n "${BRAKERRAK_SUB_STATE:-}" ]]; then
        printf '%s|%s\n' "$_RVDK_PROG_PCT" "$_RVDK_PROG_MSG" > "${BRAKERRAK_SUB_STATE}" 2>/dev/null || true
    fi

    _rvdk_prog_render
    return 0
}

rvdk_prog_cleanup() {
    local rc=$?
    local esc="$_RVDK_ESC"
    if [[ "$_RVDK_PROG_ACTIVE" == "1" && "$_RVDK_PROG_OWNER" == "1" ]]; then
        _rvdk_prog_query_geom
        local rows="$_RVDK_PROG_ROWS"
        if (( rows >= 2 )); then
            _rvdk_prog_out "${esc}7${esc}[1;${rows}r${esc}[${rows};1H${esc}[0K${esc}8"
        fi
        _RVDK_PROG_ACTIVE="0"
        _RVDK_PROG_OWNER="0"
        unset RVDK_PROGBAR_SESSION 2>/dev/null || true
    fi
    return "$rc"
}
