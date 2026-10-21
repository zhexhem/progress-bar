#!/usr/bin/env zsh
###############################################################################
# progress-bar.plugin.zsh
#
# A pure-Zsh progress bar plugin (Oh My Zsh / Zinit / Antigen / manual).
#
# Quick start:
#   pb_init bar 100 "Downloading"
#   for i in {1..100}; do pb_update bar $i; sleep 0.02; done
#
# One-liner:
#   for i in {1..100}; do progress_bar $i 100; done
#
# Wrapper:
#   with_progress 20 "Installing" -- 'sleep 0.05'
#
# Styles: block | ascii | dots | spinner | pulse | smooth
###############################################################################

# ---------------------------------------------------------------------------
# Guard against double-sourcing
# ---------------------------------------------------------------------------
[[ -n ${_PB_PLUGIN_LOADED:-} ]] && return 0
typeset -g _PB_PLUGIN_LOADED=1

# ---------------------------------------------------------------------------
# Configuration (all overridable in .zshrc before/after sourcing)
# ---------------------------------------------------------------------------
: ${PB_WIDTH:=40}
: ${PB_STYLE:=block}
: ${PB_FILLED_CHAR:='█'}
: ${PB_EMPTY_CHAR:='░'}
: ${PB_SHOW_PERCENT:=1}
: ${PB_SHOW_COUNT:=1}
: ${PB_SHOW_ETA:=1}
: ${PB_SHOW_RATE:=0}
: ${PB_SHOW_LABEL:=1}
: ${PB_COLOR:=1}
: ${PB_CLEAR_ON_FINISH:=0}
: ${PB_USE_EMOJI:=0}          # 1 → prepend a small status emoji

# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------
typeset -gA PB_COLORS
PB_COLORS=(
    reset   $'\033[0m'
    bold    $'\033[1m'
    dim     $'\033[2m'
    red     $'\033[31m'
    green   $'\033[32m'
    yellow  $'\033[33m'
    blue    $'\033[34m'
    magenta $'\033[35m'
    cyan    $'\033[36m'
    white   $'\033[37m'
)

_pb_color() {
    (( PB_COLOR )) && print -n -- "${PB_COLORS[$1]:-}"
    return 0
}

_pb_reset() {
    (( PB_COLOR )) && print -n -- "${PB_COLORS[reset]}"
    return 0
}

# Strip ANSI escapes (pure Zsh, no sed)
_pb_strip_ansi() {
    local s=$1
    print -n -- "${s//$'\033'\[[0-9;]#m/}"
}

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
typeset -gA PB_CURRENT PB_TOTAL PB_START PB_LABEL PB_WIDTH_ PB_STYLE_
typeset -gA PB_LAST_LEN PB_SPINNER_IDX

typeset -ga PB_SPINNER_FRAMES
PB_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

typeset -ga PB_PULSE_FRAMES
PB_PULSE_FRAMES=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█' '▇' '▆' '▅' '▄' '▃' '▂')

# ---------------------------------------------------------------------------
# ETA / rate helpers
# ---------------------------------------------------------------------------
_pb_eta() {
    local current=$1 total=$2 start=$3
    (( current <= 0 )) && { print -n -- "--:--"; return }
    local elapsed=$(( SECONDS - start ))
    (( elapsed <= 0 )) && elapsed=1
    if (( current >= total )); then
        printf "%02d:%02d" $(( elapsed / 60 )) $(( elapsed % 60 ))
    else
        local rem=$(( (total - current) * elapsed / current ))
        printf "%02d:%02d" $(( rem / 60 )) $(( rem % 60 ))
    fi
}

_pb_rate() {
    local current=$1 start=$2
    (( current <= 0 )) && { print -n -- "0/s"; return }
    local elapsed=$(( SECONDS - start ))
    (( elapsed <= 0 )) && elapsed=1
    printf "%d/s" $(( current / elapsed ))
}

# ---------------------------------------------------------------------------
# Render a bar into a string (no I/O)
# ---------------------------------------------------------------------------
_pb_render() {
    local name=$1
    local current=${PB_CURRENT[$name]:-0}
    local total=${PB_TOTAL[$name]:-1}
    local width=${PB_WIDTH_[$name]:-$PB_WIDTH}
    local label=${PB_LABEL[$name]:-Progress}
    local style=${PB_STYLE_[$name]:-$PB_STYLE}
    local start=${PB_START[$name]:-$SECONDS}

    (( total <= 0 )) && total=1
    (( current < 0 )) && current=0

    local percent=$(( current * 100 / total ))
    (( percent > 100 )) && percent=100

    local fill_char empty_char
    case $style in
        ascii) fill_char='#'; empty_char='-' ;;
        dots)  fill_char='●'; empty_char='○' ;;
        *)     fill_char=$PB_FILLED_CHAR; empty_char=$PB_EMPTY_CHAR ;;
    esac

    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    # Spinner / pulse frames
    local spin=""
    case $style in
        spinner)
            PB_SPINNER_IDX[$name]=$(( (${PB_SPINNER_IDX[$name]:-0} + 1) % ${#PB_SPINNER_FRAMES[@]} ))
            spin=" ${PB_SPINNER_FRAMES[$(( PB_SPINNER_IDX[$name] + 1 ))]}"
            ;;
        pulse)
            PB_SPINNER_IDX[$name]=$(( (${PB_SPINNER_IDX[$name]:-0} + 1) % ${#PB_PULSE_FRAMES[@]} ))
            spin=" ${PB_PULSE_FRAMES[$(( PB_SPINNER_IDX[$name] + 1 ))]}"
            ;;
        smooth)
            # Smooth bar: use sub-cell blocks for fractional fill
            local sub=$(( (current * width * 8 / total) % 8 ))
            local smooth_chars=(' ' '▏' '▎' '▍' '▌' '▋' '▊' '▉' '█')
            fill_char='█'
            empty_char=' '
            ;;
    esac

    local bar_filled="" bar_empty="" i
    for (( i = 0; i < filled; i++ )); do bar_filled+=$fill_char; done
    for (( i = 0; i < empty;  i++ )); do bar_empty+=$empty_char;  done

    if [[ $style == smooth ]]; then
        local sub=$(( (current * width * 8 / total) % 8 ))
        local sub_char=${smooth_chars[$((sub + 1))]:-}
        if (( filled < width )); then
            # Replace last empty cell with a fractional char
            bar_empty=${bar_empty[1,-2]}$sub_char 2>/dev/null || bar_empty=$sub_char
        fi
    fi

    local bar_color="cyan"
    if (( percent >= 100 )); then bar_color="green"
    elif (( percent >= 75 )); then bar_color="yellow"
    elif (( percent >= 50 )); then bar_color="cyan"
    fi

    local out=""
    if (( PB_USE_EMOJI )); then
        if (( percent >= 100 )); then out+="✅ "
        elif (( percent >= 50 ));  then out+="⏳ "
        else                            out+="⌛ "
        fi
    fi

    (( PB_SHOW_LABEL )) && out+="$(_pb_color bold)${label}$(_pb_reset) "
    out+="["
    out+="$(_pb_color "$bar_color")${bar_filled}$(_pb_reset)"
    out+="$(_pb_color dim)${bar_empty}$(_pb_reset)"
    out+="]"

    out+="$spin"
    (( PB_SHOW_PERCENT )) && out+=$(printf " %3d%%" "$percent")
    (( PB_SHOW_COUNT   )) && out+=$(printf " (%d/%d)" "$current" "$total")
    (( PB_SHOW_ETA     )) && out+=" ETA $(_pb_eta "$current" "$total" "$start")"
    (( PB_SHOW_RATE    )) && out+=" $(_pb_rate "$current" "$start")"

    print -n -- "$out"
}

# ---------------------------------------------------------------------------
# Draw (in-place)
# ---------------------------------------------------------------------------
_pb_draw() {
    local name=$1
    local line
    line=$(_pb_render "$name")

    local visible
    visible=$(_pb_strip_ansi "$line")
    local newlen=${#visible}
    local lastlen=${PB_LAST_LEN[$name]:-0}

    local pad=""
    if (( newlen < lastlen )); then
        pad=$(printf "%*s" $(( lastlen - newlen )) "")
    fi
    PB_LAST_LEN[$name]=$newlen

    print -rn -- $'\r'"$line""$pad"
}

# ---------------------------------------------------------------------------
# Public API — Object style
# ---------------------------------------------------------------------------

pb_init() {
    local name=$1 total=$2
    local label=${3:-Progress}
    local style=${4:-$PB_STYLE}
    local width=${5:-$PB_WIDTH}

    [[ -z $name ]] && { print -u2 "pb_init: name required"; return 1; }
    (( total <= 0 )) && total=1

    PB_CURRENT[$name]=0
    PB_TOTAL[$name]=$total
    PB_START[$name]=$SECONDS
    PB_LABEL[$name]=$label
    PB_STYLE_[$name]=$style
    PB_WIDTH_[$name]=$width
    PB_LAST_LEN[$name]=0
    PB_SPINNER_IDX[$name]=0
}

pb_update() {
    local name=$1
    if [[ -z $name || -z ${PB_TOTAL[$name]:-} ]]; then
        print -u2 "pb_update: unknown bar '$name'"
        return 1
    fi

    if (( $# >= 2 )); then
        PB_CURRENT[$name]=$2
    else
        PB_CURRENT[$name]=$(( ${PB_CURRENT[$name]:-0} + 1 ))
    fi

    _pb_draw "$name"

    if (( PB_CURRENT[$name] >= PB_TOTAL[$name] )); then
        _pb_finish_bar "$name"
    fi
}

pb_set() {
    local name=$1 key=$2 val=$3
    case $key in
        label) PB_LABEL[$name]=$val ;;
        style) PB_STYLE_[$name]=$val ;;
        width) PB_WIDTH_[$name]=$val ;;
        total) PB_TOTAL[$name]=$val ;;
        *) print -u2 "pb_set: unknown key '$key'"; return 1 ;;
    esac
}

pb_finish() {
    local name=$1
    [[ -z ${PB_TOTAL[$name]:-} ]] && return 0
    PB_CURRENT[$name]=${PB_TOTAL[$name]}
    _pb_draw "$name"
    _pb_finish_bar "$name"
}

_pb_finish_bar() {
    local name=$1
    if (( PB_CLEAR_ON_FINISH )); then
        print -rn -- $'\r\033[K'
    else
        print -n -- $'\n'
    fi
    unset "PB_CURRENT[$name]" "PB_TOTAL[$name]" "PB_START[$name]" \
          "PB_LABEL[$name]"   "PB_STYLE_[$name]" "PB_WIDTH_[$name]" \
          "PB_LAST_LEN[$name]" "PB_SPINNER_IDX[$name]"
}

# ---------------------------------------------------------------------------
# Public API — Function style
# ---------------------------------------------------------------------------
progress_bar() {
    local current=$1 total=$2
    local width=${3:-$PB_WIDTH}
    local label=${4:-Progress}
    local style=${5:-$PB_STYLE}

    local scratch="__pb_scratch__"
    if [[ -z ${PB_TOTAL[$scratch]:-} ]]; then
        pb_init "$scratch" "$total" "$label" "$style" "$width"
    else
        PB_TOTAL[$scratch]=$total
        PB_LABEL[$scratch]=$label
        PB_STYLE_[$scratch]=$style
        PB_WIDTH_[$scratch]=$width
    fi

    PB_CURRENT[$scratch]=$current
    _pb_draw "$scratch"

    if (( current >= total )); then
        _pb_finish_bar "$scratch"
    fi
}

# ---------------------------------------------------------------------------
# Wrapper: with_progress <total> <label> -- <body>
# ---------------------------------------------------------------------------
with_progress() {
    local total=$1 label=$2
    shift 2
    [[ "$1" == "--" ]] && shift

    local bar="__pb_wp_$$__"
    pb_init "$bar" "$total" "$label"

    local i
    for (( i = 1; i <= total; i++ )); do
        eval "$@"
        pb_update "$bar" "$i"
    done

    [[ -n ${PB_TOTAL[$bar]:-} ]] && pb_finish "$bar"
}

# ---------------------------------------------------------------------------
# Bonus: pb_demo
# ---------------------------------------------------------------------------
pb_demo() {
    print "→ block style"
    pb_init d1 60 "Downloading"
    for i in {1..60}; do sleep 0.02; pb_update d1 $i; done

    print "→ ascii style"
    pb_init d2 40 "Verifying" ascii 30
    for i in {1..40}; do sleep 0.02; pb_update d2 $i; done

    print "→ dots style"
    pb_init d3 40 "Packing" dots 30
    for i in {1..40}; do sleep 0.02; pb_update d3 $i; done

    print "→ spinner style"
    pb_init d4 30 "Building" spinner 25
    for i in {1..30}; do sleep 0.05; pb_update d4 $i; done

    print "→ pulse style"
    pb_init d5 20 "Watching" pulse 20
    for i in {1..20}; do sleep 0.05; pb_update d5 $i; done

    print "→ smooth style"
    pb_init d6 50 "Extracting" smooth 30
    for i in {1..50}; do sleep 0.03; pb_update d6 $i; done

    print "→ function style"
    for i in {1..40}; do sleep 0.02; progress_bar $i 40 30 "Quick"; done

    print "→ wrapper"
    with_progress 15 "Installing" -- 'sleep 0.05'
}

# ---------------------------------------------------------------------------
# Optional: zsh completion (press <TAB> after `pb_`)
# ---------------------------------------------------------------------------
_pb_completion() {
    local -a bars styles keys
    bars=(${(k)PB_TOTAL})
    styles=(block ascii dots spinner pulse smooth)
    keys=(label style width total)

    case $words[2] in
        pb_init)
            _message "bar name" ;;
        pb_update|pb_finish)
            compadd -a bars ;;
        pb_set)
            compadd -a bars; _message "key"; compadd -a keys ;;
        progress_bar)
            _message "current total [width] [label] [style]"; compadd -a styles ;;
    esac
}

if (( $+functions[compdef] )); then
    compdef _pb_completion pb_init pb_update pb_set pb_finish progress_bar with_progress 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Aliases (optional conveniences)
# ---------------------------------------------------------------------------
alias pbhelp='print -r -- "pb_init <name> <total> [label] [style] [width]
pb_update <name> [current]
pb_set <name> <label|style|width|total> <value>
pb_finish <name>
progress_bar <current> <total> [width] [label] [style]
with_progress <total> <label> -- <body>
pb_demo"' 2>/dev/null