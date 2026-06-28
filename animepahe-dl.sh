#!/usr/bin/env bash
# Download anime from animepahe in terminal
#
#/ Usage:
#/   ./animepahe-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-l] [-d]
#/
#/ Options:
#/   -a <name>               anime name
#/   -s <slug>               anime slug/uuid, can be found in $_ANIME_LIST_FILE
#/                           ignored when "-a" is enabled
#/   -e <num1,num3-num4...>  optional, episode number to download
#/                           multiple episode numbers seperated by ","
#/                           episode range using "-"
#/                           all episodes using "*"
#/   -r <resolution>         optional, specify resolution: "1080", "720"...
#/                           by default, the highest resolution is selected
#/   -o <language>           optional, specify audio language: "eng", "jpn"...
#/   -l                      optional, show m3u8 playlist link without downloading videos
#/   -d                      enable debug mode
#/   -h | --help             display this help message

set -e
set -u

usage() {
    printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)" && exit 1
}

refresh_cf_clearance() {
    # Calls CF-Clearance-Scraper to obtain a fresh cf_clearance cookie and user-agent.
    # Reads scraper config from config.json:
    #   .scraper_path  – path to the CF-Clearance-Scraper directory (default: same dir as this script)
    #   .scraper_ua    – user-agent to pass to the scraper (default: built-in Chrome UA)
    #   .scraper_timeout – timeout in seconds passed to -t (default: 60)
    # On success, sets _CF_CLEARANCE and _USER_AGENT globals.

    local scraper_dir scraper_venv scraper_python scraper_ua scraper_timeout scraper_output cookie_file
    local config="$_SCRIPT_PATH/config.json"

    # Read optional overrides from config.json (fall back to sensible defaults)
    scraper_dir="$("$_JQ" -r '.scraper_path // empty' "$config" 2>/dev/null)"
    scraper_dir="${scraper_dir:-$_SCRIPT_PATH/CF-Clearance-Scraper}"

    # venv path: defaults to a "cf-scraper" venv sibling of the scraper directory
    scraper_venv="$("$_JQ" -r '.scraper_venv // empty' "$config" 2>/dev/null)"
    scraper_venv="${scraper_venv:-$scraper_dir/cf-scraper}"

    # Use the venv's python binary directly — no need to activate
    scraper_python="$scraper_venv/bin/python"
    if [[ ! -x "$scraper_python" ]]; then
        print_error "CF scraper venv python not found at '$scraper_python'. Set 'scraper_venv' in config.json to the correct venv path."
    fi

    scraper_ua="$("$_JQ" -r '.scraper_ua // empty' "$config" 2>/dev/null)"
    scraper_ua="${scraper_ua:-Mozilla/5.0 (X11; Linux x86_64; rv:152.0) Gecko/20100101 Firefox/152.0}"

    scraper_timeout="$("$_JQ" -r '.scraper_timeout // empty' "$config" 2>/dev/null)"
    scraper_timeout="${scraper_timeout:-60}"

    cookie_file="$(mktemp /tmp/cf_cookies_XXXXXX.json)"

    print_info "Running CF-Clearance-Scraper to obtain fresh cf_clearance..."

    # Run the scraper using the venv python; capture combined stdout+stderr to parse the cookie line
    scraper_output="$(
        cd "$scraper_dir" && \
        "$scraper_python" main.py \
            -t "$scraper_timeout" \
            -ua "$scraper_ua" \
            -f "$cookie_file" \
            "$_HOST/api?m=search" \
            2>&1
    )" || true

    # Extract cf_clearance value from the scraper log line:
    #   [INFO] Cookie: cf_clearance=<value>
    local new_cf
    new_cf="$(grep -oP '(?<=Cookie: cf_clearance=)\S+' <<< "$scraper_output" | tail -1)"

    if [[ -z "${new_cf:-}" ]]; then
        # Fall back to reading from the dumped cookie JSON if the log line was absent
        new_cf="$("$_JQ" -r '.[] | select(.name=="cf_clearance") | .value' "$cookie_file" 2>/dev/null | tail -1)"
    fi

    rm -f "$cookie_file"

    if [[ -z "${new_cf:-}" ]]; then
        print_error "CF-Clearance-Scraper did not return a cf_clearance cookie. Output was:\n$scraper_output"
    fi

    _CF_CLEARANCE="$new_cf"
    _USER_AGENT="$scraper_ua"
    print_info "cf_clearance refreshed successfully."
}

set_var() {
    _CURL="$(command -v curl)" || command_not_found "curl"
    _JQ="$(command -v jq)" || command_not_found "jq"
    _FZF="$(command -v fzf)" || command_not_found "fzf"
    _FFMPEG="$(command -v ffmpeg)" || command_not_found "ffmpeg"

    _HOST="https://animepahe.pw"
    _ANIME_URL="$_HOST/anime"
    _API_URL="$_HOST/api"
    _REFERER_URL="https://kwik.cx/"
    _REFERER_HOST="https://animepahe.pw/"

    _SCRIPT_PATH=$(dirname "$(realpath "$0")")
    _DOWNLOAD_PATH="/mnt/user/data/media/unsorted"
    _ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
    _SOURCE_FILE=".source.json"

    # Dynamically obtain cf_clearance and user-agent via the CF scraper.
    # If you prefer to use static values from config.json instead, comment out
    # the refresh_cf_clearance call below and uncomment the two lines after it.
    refresh_cf_clearance
    # _USER_AGENT="$("$_JQ" -r '.ua' "$_SCRIPT_PATH/config.json")"
    # _CF_CLEARANCE="$("$_JQ" -r '.cf' "$_SCRIPT_PATH/config.json")"
}

install_dependencies_if_needed() {
    local install_needed=false
    local _cwd
    _cwd="$(pwd)"

    if ! command -v fzf >/dev/null; then
        echo "[INFO] fzf not found. Installing..."
        install_needed=true
    fi

    if ! command -v ffmpeg >/dev/null; then
        echo "[INFO] ffmpeg not found. Installing..."
        install_needed=true
    fi

    if [ "$install_needed" = true ]; then
        local FZF_VERSION="v0.64.0"
        local FZF_FILE="fzf-0.64.0-linux_amd64.tar.gz"
        local FZF_URL="https://github.com/junegunn/fzf/releases/download/${FZF_VERSION}/${FZF_FILE}"
        local FFMPEG_VERSION="6.1"
        local FFMPEG_FILE="ffmpeg-master-latest-linux64-gpl.tar.xz"
        local FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/${FFMPEG_FILE}"

        echo "[INFO] Creating temp workspace..."
        local WORKDIR
        WORKDIR="$(mktemp -d)"
        cd "$WORKDIR"

        if ! command -v fzf >/dev/null; then
            echo "[INFO] Downloading fzf ${FZF_VERSION}..."
            wget -q --show-progress "$FZF_URL"
            tar -xzf "$FZF_FILE"
            chmod +x fzf
            mv fzf /usr/local/bin/
        fi

        if ! command -v ffmpeg >/dev/null; then
            echo "[INFO] Downloading ffmpeg ${FFMPEG_VERSION}..."
            wget -q --show-progress "$FFMPEG_URL"
            tar -xf "$FFMPEG_FILE"
            cd ffmpeg-master-latest-linux64-gpl/bin/
            chmod +x ffmpeg ffprobe
            mv ffmpeg ffprobe /usr/local/bin/
        fi

        echo "[INFO] Cleaning up..."
        rm -rf "$WORKDIR"
        cd "$_cwd"
    fi
}

set_args() {
    expr "$*" : ".*--help" > /dev/null && usage
    _DEFAULT_ANIME_RESOLUTION="720"
    while getopts ":hlda:s:e:r:o:" opt; do
        case $opt in
            a)
                _INPUT_ANIME_NAME="$OPTARG"
                ;;
            s)
                _ANIME_SLUG="$OPTARG"
                ;;
            e)
                _ANIME_EPISODE="$OPTARG"
                ;;
            l)
                _LIST_LINK_ONLY=true
                ;;
            r)
                _ANIME_RESOLUTION="$OPTARG"
                ;;
            o)
                _ANIME_AUDIO="$OPTARG"
                ;;
            d)
                _DEBUG_MODE=true
                set -x
                ;;
            h)
                usage
                ;;
            \?)
                print_error "Invalid option: -$OPTARG"
                ;;
        esac
    done
}

print_info() {
    # $1: info message
    [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[32m[INFO]\033[0m $1" >&2
}

print_warn() {
    # $1: warning message
    [[ -z "${_LIST_LINK_ONLY:-}" ]] && printf "%b\n" "\033[33m[WARNING]\033[0m $1" >&2
}

print_error() {
    # $1: error message
    printf "%b\n" "\033[31m[ERROR]\033[0m $1" >&2
    exit 1
}

command_not_found() {
    # $1: command name
    print_error "$1 command not found!"
}

get() {
    # $1: url
    "$_CURL" -sS -L "$1" -b "cf_clearance=$_CF_CLEARANCE" -A "$_USER_AGENT" --compressed

}

download_anime_list() {
    get "$_ANIME_URL" \
    | grep "/anime/" \
    | sed -E 's/.*anime\//[/;s/" title="/] /;s/\">.*/   /;s/" title/]/' \
    > "$_ANIME_LIST_FILE"
}

search_anime_by_name() {
    # $1: anime name
    local d n
    d="$(get "$_HOST/api?m=search&q=${1// /%20}")"
    n="$("$_JQ" -r '.total' <<< "$d" 2>/dev/null)"
    [[ -z "${n:-}" ]] && print_error "No search result... Need a new cf value in config.json"
    if [[ "$n" -eq "0" ]]; then
        echo ""
    else
        "$_JQ" -r '.data[] | "[\(.session)] \(.title)   "' <<< "$d" \
            | tee -a "$_ANIME_LIST_FILE" \
            | remove_slug
    fi
}

get_episode_list() {
    # $1: anime id
    # $2: page number
    get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=${2}"
}

download_source() {
    local d p n i
    mkdir -p "$_DOWNLOAD_PATH/$_ANIME_NAME"
    d="$(get_episode_list "$_ANIME_SLUG" "1")"
    p="$("$_JQ" -r '.last_page' <<< "$d" 2>/dev/null)"
    [[ -z "${p:-}" ]] && print_error "No search result... Need a new cf value in config.json"

    # Check if we already have cached episodes and didn't explicitly request all
    local cached_source="$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE"
    local should_fetch_all=true
    
    if [[ -f "$cached_source" && -z "${_ANIME_EPISODE:-}" ]]; then
        local cached_count
        cached_count="$("$_JQ" -r '.data | length' "$cached_source" 2>/dev/null || echo 0)"
        if [[ "$cached_count" -gt 0 ]]; then
            should_fetch_all=false
            # Only fetch the last page to check for new episodes
            if [[ "$p" -gt "1" ]]; then
                print_info "Checking for new episodes (page $p of $p)..."
                n="$(get_episode_list "$_ANIME_SLUG" "$p")"
                ensure_json_response "$n" "episode list page $p"
                d="$(echo "$d $n" | "$_JQ" -s '.[0].data + .[1].data | {data: .}')"
            fi
        fi
    fi

    # If we need to fetch all pages, do so with progress indicator
    if [[ "$should_fetch_all" == true && "$p" -gt "1" ]]; then
        for i in $(seq 2 "$p"); do
            print_info "Fetching episodes (page $i of $p)..."
            n="$(get_episode_list "$_ANIME_SLUG" "$i")"
            ensure_json_response "$n" "episode list page $i"
            d="$(echo "$d $n" | "$_JQ" -s '.[0].data + .[1].data | {data: .}')"
        done
    fi

    echo "$d" > "$cached_source"
}

get_episode_link() {
    # $1: episode number
    local s o l r=""
    s=$("$_JQ" -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' --arg num "$1" < "$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE")
    [[ "$s" == "" ]] && print_warn "Episode $1 not found!" && return
    o="$(get "${_HOST}/play/${_ANIME_SLUG}/${s}")"

    l="$(grep \<button <<< "$o" \
        | grep data-src \
        | sed -E 's/data-src="/\n/g' \
        | grep 'data-av1="0"')"

    if [[ -n "${_ANIME_AUDIO:-}" ]]; then
        print_info "Select audio language: $_ANIME_AUDIO"
        r="$(grep 'data-audio="'"$_ANIME_AUDIO"'"' <<< "$l")"
        if [[ -z "${r:-}" ]]; then
            print_warn "Selected audio language is not available, fallback to default."
        fi
    fi

    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        print_info "Select video resolution: ${_ANIME_RESOLUTION}p"
        r="$(grep 'data-resolution="'"$_ANIME_RESOLUTION"'"' <<< "${r:-$l}")"
        if [[ -z "${r:-}" ]]; then
            print_warn "Selected video resolution is not available, fallback to default ${_DEFAULT_ANIME_RESOLUTION}p."
        fi
    fi

    if [[ -z "${r:-}" ]]; then
        grep kwik <<< "$l" | grep kwik | grep "$_DEFAULT_ANIME_RESOLUTION" | awk -F '"' '{print $1}'
    else
        awk -F '" ' '{print $1}' <<< "$r"
    fi

}
run_js_code() {
    # $1: js code
    curl -sS -X POST 'https://glot.io/run/javascript?version=latest' \
        -H 'Content-Type: application/json' \
        --data-raw $'{"files":[{"name":"main.js","content":"'"$1"'"}],"stdin":"","command":"node main.js"}'
}

get_playlist_link() {
    # $1: episode link
    local s l t
    while read -r t; do
        s="$("$_CURL" --compressed -sS -H "Referer: $_REFERER_HOST" "$t" \
            | grep "<script>eval" \
            | awk -F 'script>' '{print $2}' \
            | sed 's/\\/\\\\/g' \
            | sed 's/"/\\"/g')"

        l="$(run_js_code "$s" \
            | "$_JQ" -r .stderr \
            | grep 'source=' \
            | sed 's/.m3u8.*/.m3u8/' \
            | sed 's/.*https/https/')"

        if [[ -n "${l:-}" ]]; then
            echo "$l"
            return
        fi
    done <<< "$1"
}

download_episodes() {
    # $1: episode number string
    local origel el uniqel
    origel=()
    if [[ "$1" == *","* ]]; then
        IFS="," read -ra ADDR <<< "$1"
        for n in "${ADDR[@]}"; do
            origel+=("$n")
        done
    else
        origel+=("$1")
    fi

    el=()
    for i in "${origel[@]}"; do
        if [[ "$i" == *"*"* ]]; then
            local eps fst lst
            eps="$("$_JQ" -r '.data[].episode' "$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE" | sort -nu)"
            fst="$(head -1 <<< "$eps")"
            lst="$(tail -1 <<< "$eps")"
            i="${fst}-${lst}"
        fi

        if [[ "$i" == *"-"* ]]; then
            s=$(awk -F '-' '{print $1}' <<< "$i")
            e=$(awk -F '-' '{print $2}' <<< "$i")
            for n in $(seq "$s" "$e"); do
                el+=("$n")
            done
        else
            el+=("$i")
        fi
    done

    IFS=" " read -ra uniqel <<< "$(printf '%s\n' "${el[@]}" | sort -n -u | tr '\n' ' ')"

    [[ ${#uniqel[@]} == 0 ]] && print_error "Wrong episode number!"

    for e in "${uniqel[@]}"; do
        download_episode "$e"
    done
}

generate_filelist() {
    # $1: playlist file
    # $2: output file
    grep "^https" "$1" \
        | sed -E "s/https.*\//file '/" \
        | sed -E "s/$/'/" \
        > "$2"
}

# new: persist/load last downloaded episode per anime+stream (audio+resolution)
save_last_episode() {
    # $1: episode number
    local ep="$1"
    local key="${_ANIME_AUDIO:-default}_${_ANIME_RESOLUTION:-default}"
    local f="$_DOWNLOAD_PATH/$_ANIME_NAME/.last.${key}"
    mkdir -p "$_DOWNLOAD_PATH/$_ANIME_NAME"
    printf "%d" "$ep" > "$f"
}

load_last_episode() {
    local key="${_ANIME_AUDIO:-default}_${_ANIME_RESOLUTION:-default}"
    local f="$_DOWNLOAD_PATH/$_ANIME_NAME/.last.${key}"
    if [[ -f "$f" ]]; then
        cat "$f"
    else
        echo ""
    fi
}

# new: given saved last episode, return created_at and computed ETA/check-again dates
get_last_release_info() {
    # uses: _DOWNLOAD_PATH _ANIME_NAME _SOURCE_FILE _JQ
    # returns via globals: last_ep last_created_at last_epoch eta_epoch eta_date now_epoch
    last_ep="$(load_last_episode)"
    last_created_at=""
    eta_date=""
    if [[ -n "${last_ep:-}" ]]; then
        last_created_at="$("$_JQ" -r --arg num "$last_ep" '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .created_at' "$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE" 2>/dev/null || true)"
        if [[ -n "${last_created_at:-}" && "${last_created_at}" != "null" ]]; then
            # parse created_at to epoch (Linux date -d)
            last_epoch=$(date -d "$last_created_at" +%s 2>/dev/null || echo "")
            if [[ -n "$last_epoch" ]]; then
                eta_epoch=$((last_epoch + 7*24*3600))
                eta_date="$(date -d "@$eta_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")"
                now_epoch=$(date +%s)
            fi
        fi
    fi
}

download_episode() {
    # $1: episode number
    local num="$1" l pl v erropt='' extpicky=''
    local anime_prefix

    # Use _INPUT_ANIME_NAME if set, otherwise fallback to _ANIME_NAME
    anime_prefix="${_INPUT_ANIME_NAME:-$_ANIME_NAME}"
    # Sanitize anime_prefix for filesystem
    anime_prefix="$(echo "$anime_prefix" | sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g' | sed -E 's/[[:space:]]+$//')"

    # detect season number from anime_prefix like "Season 2", "season_2", "Season-2"
    season_num=1
    # Prefer explicit season in anime_prefix (user-provided name), but if missing
    # fall back to the full _ANIME_NAME which often contains "Season N".
    if [[ "$anime_prefix" =~ [Ss]eason[[:space:]_-]*([0-9]+) ]]; then
        season_num="${BASH_REMATCH[1]}"
    elif [[ "${_ANIME_NAME:-}" =~ [Ss]eason[[:space:]_-]*([0-9]+) ]]; then
        season_num="${BASH_REMATCH[1]}"
    fi
    season_fmt=$(printf "S%02d" "$season_num")

    # Format episode number as two digits
    local epnum
    epnum=$(printf "%02d" "$num")
    v="$_DOWNLOAD_PATH/${_ANIME_NAME}/${_ANIME_NAME} - ${season_fmt}E${epnum}.mp4"

    l=$(get_episode_link "$num")
    [[ "$l" != *"/"* ]] && print_warn "Wrong download link or episode $1 not found!" && return

    pl=$(get_playlist_link "$l")
    [[ -z "${pl:-}" ]] && print_warn "Missing video list! Skip downloading!" && return

    if [[ -z ${_LIST_LINK_ONLY:-} ]]; then
        print_info "Downloading Episode $1..."

        [[ -z "${_DEBUG_MODE:-}" ]] && erropt="-v error"
        if ffmpeg -h full 2>/dev/null| grep extension_picky >/dev/null; then
            extpicky="-extension_picky 0"
        fi

        "$_FFMPEG" $extpicky -headers "Referer: $_REFERER_URL" -i "$pl" -c copy $erropt -y "$v"

    else
        echo "$pl"
    fi
}

select_episodes_to_download() {
    [[ "$(grep 'data' -c "$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE")" -eq "0" ]] && print_error "No episode available!"
    "$_JQ" -r '.data[] | "[\(.episode | tonumber)] E\(.episode | tonumber) \(.created_at)"' "$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE" >&2
    echo -n "Which episode(s) to download: " >&2
    read -r s
    echo "$s"
}

remove_brackets() {
    awk -F']' '{print $1}' | sed -E 's/^\[//'
}

remove_slug() {
    awk '{$1="";print}' | awk '{$1=$1;print}'
}

get_slug_from_name() {
    # $1: anime name
    [[ -z "${1:-}" ]] && return 1
    grep -F "] $1" "$_ANIME_LIST_FILE" | tail -1 | remove_brackets
}

check_config() {
    if [[ -z "${_CF_CLEARANCE:-}" ]]; then
        print_error "cf_clearance is empty. The CF-Clearance-Scraper may have failed. Check that 'scraper_path' in config.json points to the CF-Clearance-Scraper directory."
    fi
    if [[ -z "${_USER_AGENT:-}" ]]; then
        print_error "User-agent is empty. Check 'scraper_ua' in config.json or the scraper output."
    fi
}

main() {
    install_dependencies_if_needed
    set_args "$@"
    set_var
    check_config

    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        _ANIME_NAME=$("$_FZF" -1 <<< "$(search_anime_by_name "$_INPUT_ANIME_NAME")")
        [[ -z "${_ANIME_NAME:-}" ]] && print_error "Anime not found for search: $_INPUT_ANIME_NAME"
        _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
    else
        download_anime_list
        if [[ -z "${_ANIME_SLUG:-}" ]]; then
            _ANIME_NAME=$("$_FZF" -1 <<< "$(remove_slug < "$_ANIME_LIST_FILE")")
            _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
        fi
    fi

    [[ "$_ANIME_SLUG" == "" ]] && print_error "Anime slug not found!"
    _ANIME_NAME="$(grep "$_ANIME_SLUG" "$_ANIME_LIST_FILE" \
        | tail -1 \
        | remove_slug \
        | sed -E 's/[[:space:]]+$//' \
        | sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g')"

    if [[ "$_ANIME_NAME" == "" ]]; then
        print_warn "Anime name not found! Try again."
        download_anime_list
        exit 1
    fi

    download_source

    # improved behavior: if user did not specify episodes, try to auto-increment from saved state
    if [[ -z "${_ANIME_EPISODE:-}" ]]; then
        get_last_release_info
        if [[ -n "${last_ep:-}" ]]; then
            # attempt to compute next episode and check availability
            next=$((last_ep + 1))
            # check if `next` is available
            found="$("$_JQ" -r --arg num "$next" '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .episode' "$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE" 2>/dev/null || true)"
            if [[ -n "$found" ]]; then
                # collect contiguous episodes starting from next (e.g. 20,21,22,23 -> 20-23)
                start="$next"
                last="$next"
                while true; do
                    candidate=$((last + 1))
                    has="$("$_JQ" -r --arg num "$candidate" '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .episode' "$_DOWNLOAD_PATH/$_ANIME_NAME/$_SOURCE_FILE" 2>/dev/null || true)"
                    if [[ -n "$has" ]]; then
                        last="$candidate"
                    else
                        break
                    fi
                done
                if [[ "$last" -gt "$start" ]]; then
                    print_info "Previous last downloaded episode for this anime was $last_ep. Will download episodes: ${start}-${last}"
                    _ANIME_EPISODE="${start}-${last}"
                else
                    print_info "Previous last downloaded episode for this anime was $last_ep. Will try to download episode $next next."
                    _ANIME_EPISODE="$next"
                fi
            else
                # next not found -> show human readable last release and ETA/check-again
                # dates
                if [[ -n "${last_created_at:-}" && -n "${eta_date:-}" ]]; then
                    if [[ "$now_epoch" -lt "$eta_epoch" ]]; then
                        print_info "Last released episode: ${last_ep} at ${last_created_at}"
                        print_info "Estimated next release: ${eta_date}"
                    else
                        # already more than 7 days past ETA
                        check_again_epoch=$(( now_epoch + 7*24*3600 ))
                        check_again_date="$(date -d "@$check_again_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")"
                        print_info "Last released episode: ${last_ep} at ${last_created_at}"
                        print_info "It's been more than 7 days since the last release; the series may be on hiatus."
                        print_info "Consider checking again by: ${check_again_date}"
                    fi
                fi

                # ask user whether to select episodes now
                echo -n "Do you want to select episodes to download now? [y/N] " >&2
                read -r _ans
                case "$_ans" in
                    [Yy]|[Yy][Ee][Ss])
                        _ANIME_EPISODE=$(select_episodes_to_download)
                        ;;
                    *)
                        print_info "OK. Exiting."
                        exit 0
                        ;;
                esac
            fi
        fi
    fi

    [[ -z "${_ANIME_EPISODE:-}" ]] && _ANIME_EPISODE=$(select_episodes_to_download)
    download_episodes "$_ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
