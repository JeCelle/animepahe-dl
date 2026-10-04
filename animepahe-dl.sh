#!/usr/bin/env bash

# Download anime from animepahe in terminal
#
#/ Usage:
#/   ./animepahe-dl.sh [-a <anime name>] [-s <anime_slug>] [-e <episode_num1,num2,num3-num4...>] [-r <resolution>] [-l] [-d]
#/
#/ Options:
#/   -a <name>               anime name
#/                           if the search/browse list has more than one match
#/                           (e.g. multiple seasons of the same show), use TAB
#/                           in the fzf picker to select several entries and
#/                           they will be queued and downloaded one after another
#/                           in this same session
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
#/
#/ Environment:
#/   FLARESOLVERR_URL        service URL (default: http://192.168.5.111:8191)
#/                           set empty to use manual cf updates only

set -e
set -u

usage() {
    printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)" && exit 1
}

set_var() {
    _CURL="$(command -v curl)" || command_not_found "curl"
    _JQ="$(command -v jq)" || command_not_found "jq"
    _FZF="$(command -v fzf)" || command_not_found "fzf"
    _YTDLP="$(command -v yt-dlp)" || command_not_found "yt-dlp"
    _NODE="$(command -v node)" || command_not_found "node"

    _HOST="https://animepahe.pw"
    _ANIME_URL="$_HOST/anime"
    _API_URL="$_HOST/api"
    _REFERER_URL="https://kwik.cx/"
    _REFERER_HOST="https://animepahe.pw/"

    _SCRIPT_PATH=$(dirname "$(realpath "$0")")
    _DOWNLOAD_PATH="/mnt/user/data/media/unsorted"
    _CONFIG_FILE="$_SCRIPT_PATH/config.json"
    _USER_AGENT="$("$_JQ" -r '.ua // empty' "$_CONFIG_FILE")"
    _CF_CLEARANCE="$("$_JQ" -r '.cf // empty' "$_CONFIG_FILE")"
    _FLARESOLVERR_URL="${FLARESOLVERR_URL-http://192.168.5.111:8191}"
    _ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
    _SOURCE_FILE=".source.json"
}

install_dependencies_if_needed() {
    local install_needed=false
    local _cwd
    _cwd="$(pwd)"

    if ! command -v fzf >/dev/null 2>&1; then
        echo "[INFO] fzf not found. Installing..."
        install_needed=true
    fi

    if ! command -v yt-dlp >/dev/null 2>&1; then
        echo "[INFO] yt-dlp not found. Installing..."
        install_needed=true
    fi

    if [ "$install_needed" = true ]; then
        local FZF_VERSION="v0.64.0"
        local FZF_FILE="fzf-0.64.0-linux_amd64.tar.gz"
        local FZF_URL="https://github.com/junegunn/fzf/releases/download/${FZF_VERSION}/${FZF_FILE}"

        local YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux"

        echo "[INFO] Creating temp workspace..."
        local WORKDIR
        WORKDIR="$(mktemp -d)"
        cd "$WORKDIR" || exit 1

        if ! command -v fzf >/dev/null 2>&1; then
            echo "[INFO] Downloading fzf ${FZF_VERSION}..."
            wget -q --show-progress "$FZF_URL"
            tar -xzf "$FZF_FILE"
            chmod +x fzf
            mv fzf /usr/local/bin/
        fi

        if ! command -v yt-dlp >/dev/null 2>&1; then
            echo "[INFO] Downloading latest yt-dlp..."
            wget -q --show-progress -O yt-dlp "$YTDLP_URL"
            chmod +x yt-dlp
            mv yt-dlp /usr/local/bin/
        fi

        echo "[INFO] Cleaning up..."
        cd "$_cwd" || exit 1
        rm -rf "$WORKDIR"
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

refresh_cf_with_flaresolverr() {
    local payload response cf ua tmp
    print_info "Refreshing Cloudflare clearance with FlareSolverr..."
    payload="$("$_JQ" -n --arg url "$_HOST/" \
        '{cmd: "request.get", url: $url, maxTimeout: 60000, returnOnlyCookies: true}')"
    if ! response="$("$_CURL" -fsS --connect-timeout 5 --max-time 70 \
        -H 'Content-Type: application/json' --data "$payload" \
        "${_FLARESOLVERR_URL%/}/v1")"; then
        print_warn "Could not reach FlareSolverr or its request failed."
        return 1
    fi
    if ! "$_JQ" -e '.status == "ok" and (.solution.status == 200)' \
        >/dev/null 2>&1 <<< "$response"; then
        print_warn "FlareSolverr could not solve the Cloudflare challenge."
        return 1
    fi
    cf="$("$_JQ" -r '[.solution.cookies[]? | select(.name == "cf_clearance") | .value][0] // empty' <<< "$response")"
    ua="$("$_JQ" -r '.solution.userAgent // empty' <<< "$response")"
    if [[ -z "$cf" || "$cf" =~ [[:space:]\;\,] || -z "$ua" || "$ua" == *$'\n'* || "$ua" == *$'\r'* ]]; then
        print_warn "FlareSolverr did not return a valid clearance cookie and user-agent."
        return 1
    fi
    tmp="$(mktemp "$_SCRIPT_PATH/.config.json.XXXXXX")" || return 1
    if ! "$_JQ" --arg cf "$cf" --arg ua "$ua" '.cf = $cf | .ua = $ua' \
        "$_CONFIG_FILE" > "$tmp" || ! mv "$tmp" "$_CONFIG_FILE"; then
        rm -f "$tmp"
        print_warn "Could not save FlareSolverr clearance in config.json."
        return 1
    fi
    print_info "Updated clearance and user-agent. Retrying..."
    return 0
}

get() {
    # Reload credentials: callers often run in command-substitution subshells.
    local response status cf ua
    cf="$("$_JQ" -r '.cf // empty' "$_CONFIG_FILE")" || return 1
    ua="$("$_JQ" -r '.ua // empty' "$_CONFIG_FILE")" || return 1
    response="$("$_CURL" -sS -L "$1" -b "cf_clearance=$cf" -A "$ua" \
        --compressed -w $'\n%{http_code}')" || return 1
    status="${response##*$'\n'}"
    response="${response%$'\n'*}"
    # Successful pages also contain Cloudflare background scripts.
    if [[ "$1" == "$_HOST/"* && -n "${_FLARESOLVERR_URL:-}" ]] && \
        { [[ "$status" == 403 || "$status" == 503 ]] || \
          grep -qiE '<title>[[:space:]]*Just a moment' <<< "$response"; }; then
        if refresh_cf_with_flaresolverr; then
            cf="$("$_JQ" -r '.cf' "$_CONFIG_FILE")" || return 1
            ua="$("$_JQ" -r '.ua' "$_CONFIG_FILE")" || return 1
            "$_CURL" -sS -L "$1" -b "cf_clearance=$cf" -A "$ua" --compressed
            return $?
        fi
    fi
    printf '%s\n' "$response"
}

refresh_cf_clearance() {
    local cf tmp

    if [[ ! -t 0 ]]; then
        print_error "AnimePahe requires a new cf value in config.json, but stdin is not interactive."
    fi

    print_warn "AnimePahe requires a new cf value."
    printf "Enter new cf value: " >&2
    IFS= read -r cf || print_error "Could not read new cf value."
    cf="${cf#"${cf%%[![:space:]]*}"}"
    cf="${cf%"${cf##*[![:space:]]}"}"

    if [[ -z "$cf" || "$cf" =~ [[:space:]\;\,] ]]; then
        print_error "Invalid cf value. It must be non-empty and contain no whitespace, semicolon, or comma."
    fi

    tmp="$(mktemp "$_SCRIPT_PATH/.config.json.XXXXXX")"
    if ! "$_JQ" --arg cf "$cf" '.cf = $cf' "$_CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        print_error "Could not update cf in config.json."
    fi
    mv "$tmp" "$_CONFIG_FILE"
    _CF_CLEARANCE="$cf"
    print_info "Updated config.json. Retrying..."
}

download_anime_list() {
    get "$_ANIME_URL" \
    | grep "/anime/" \
    | sed -E 's/.*anime\//[/;s/" title="/] /;s/\">.*/   /;s/" title/]/' \
    > "$_ANIME_LIST_FILE"
}

dedupe_anime_list() {
    # keep only the last occurrence of each unique slug, preserve file order otherwise
    [[ -f "$_ANIME_LIST_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    tac "$_ANIME_LIST_FILE" \
        | awk -F']' '!seen[$1]++' \
        | tac \
        > "$tmp"
    mv "$tmp" "$_ANIME_LIST_FILE"
}

search_anime_by_name() {
    # $1: anime name
    local d n
    d="$(get "$_HOST/api?m=search&q=${1// /%20}")"
    n="$("$_JQ" -r '.total' <<< "$d" 2>/dev/null || true)"
    if [[ -z "${n:-}" || "$n" == "null" ]]; then
        if [[ -n "${_CF_REFRESH_RETRY:-}" ]]; then
            print_error "AnimePahe search failed after retrying with updated cf value."
        fi
        refresh_cf_clearance
        return 2
    fi
    if [[ "$n" -eq "0" ]]; then
        echo ""
    else
        "$_JQ" -r '.data[] | "[\(.session)] \(.title)   "' <<< "$d" \
            | tee -a "$_ANIME_LIST_FILE" \
            | remove_slug
        dedupe_anime_list
    fi
}

get_episode_list() {
    # $1: anime id
    # $2: page number
    get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=${2}"
}

download_source() {
    local d p n i cf_retry=false
    mkdir -p "$_DOWNLOAD_PATH/$_ANIME_NAME"
    while true; do
        d="$(get_episode_list "$_ANIME_SLUG" "1")"
        p="$("$_JQ" -r '.last_page' <<< "$d" 2>/dev/null || true)"
        [[ -n "${p:-}" && "$p" != "null" ]] && break
        if [[ "$cf_retry" == true ]]; then
            print_error "AnimePahe episode lookup failed after retrying with updated cf value."
        fi
        refresh_cf_clearance
        cf_retry=true
    done

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
                d="$(echo "$d $n" | "$_JQ" -s '.[0].data + .[1].data | {data: .}')"
            fi
        fi
    fi

    # If we need to fetch all pages, do so with progress indicator
    if [[ "$should_fetch_all" == true && "$p" -gt "1" ]]; then
        for i in $(seq 2 "$p"); do
            print_info "Fetching episodes (page $i of $p)..."
            n="$(get_episode_list "$_ANIME_SLUG" "$i")"
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
    "$_NODE" -e '
        const vm = require("vm");
        const video = { set src(value) { throw new Error("source=" + value); } };
        const sandbox = { document: { cookie: "", querySelector() { return video; } }, window: {}, Hls: { isSupported() { return false; } }, Plyr: function () {}, screen: { orientation: { lock() {} } } };
        try { vm.runInNewContext(process.argv[1], sandbox, { timeout: 5000 }); }
        catch (error) { console.error(error.stack || error); }
    ' "$1" 2>&1
}

get_playlist_link() {
    # $1: episode link
    local s l t
    while read -r t; do
        s="$("$_CURL" --compressed -sS -H "Referer: $_REFERER_HOST" "$t" \
            | grep "<script>eval" \
            | awk -F 'script>' '{print $2}')"

        l="$(run_js_code "$s" \
            | sed -n 's/^Error: source=\(https:\/\/[^[:space:]]*\.m3u8\).*/\1/p')"

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

        "$_YTDLP" "$pl" --referer "$_REFERER_URL" --impersonate chrome --no-warnings -q --progress -o "$v"
        if [[ $? -eq 0 ]]; then
            save_last_episode "$num"
        else
            print_warn "yt-dlp failed for episode $num, not marking as last downloaded."
        fi

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
    local name="$1"
    [[ -z "$name" ]] && return 1

    awk -F']' -v want="$name" '{
        title = $0
        sub(/^[^]]*\]/, "", title)
        gsub(/^[ \t]+|[ \t]+$/, "", title)
        if (title == want) print $0
    }' "$_ANIME_LIST_FILE" | tail -n1 | remove_brackets
}

check_config() {
    if [[ -z "${_CF_CLEARANCE:-}" && -z "${_FLARESOLVERR_URL:-}" ]]; then
        print_error "Missing cf_clearance, please add it in config.json!"
    fi
    if [[ -z "${_USER_AGENT:-}" && -z "${_FLARESOLVERR_URL:-}" ]]; then
        print_error "Missing user-agent, please add it in config.json!"
    fi
}

process_one_anime() {
    # uses/sets globals: _ANIME_SLUG _ANIME_NAME _ANIME_EPISODE
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

                # ask user whether to select episodes now (skip prompt in unattended
                # queue mode — just move on to the next queued anime/season)
                if [[ "${total:-1}" -gt 1 ]]; then
                    print_info "No new episode available yet for $_ANIME_NAME; skipping in unattended queue mode."
                    return 0
                fi
                echo -n "Do you want to select episodes to download now? [y/N] " >&2
                read -r _ans
                case "$_ans" in
                    [Yy]|[Yy][Ee][Ss])
                        _ANIME_EPISODE=$(select_episodes_to_download)
                        ;;
                    *)
                        print_info "OK. Exiting."
                        return 0
                        ;;
                esac
            fi
        fi
    fi

    if [[ -z "${_ANIME_EPISODE:-}" ]]; then
        if [[ "${total:-1}" -gt 1 ]]; then
            # unattended queue mode: no explicit -e and nothing downloaded before,
            # so just grab everything available for this season rather than prompt
            print_info "No -e given and no prior download state for $_ANIME_NAME; downloading all available episodes."
            _ANIME_EPISODE="*"
        else
            _ANIME_EPISODE=$(select_episodes_to_download)
        fi
    fi
    download_episodes "$_ANIME_EPISODE"
}

main() {
    install_dependencies_if_needed
    set_args "$@"
    set_var
    check_config

    # remember whatever episode spec the user passed on the command line (if any)
    # so it can be re-applied fresh to every queued anime/season below
    local _ANIME_EPISODE_ARG="${_ANIME_EPISODE:-}"
    local -a selected_names=()

    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        local_search_status=0
        search_results=$(search_anime_by_name "$_INPUT_ANIME_NAME") || local_search_status=$?
        if [[ "$local_search_status" -eq 2 ]]; then
            _CF_CLEARANCE="$("$_JQ" -r '.cf' "$_CONFIG_FILE")"
            search_results=$( _CF_REFRESH_RETRY=true; search_anime_by_name "$_INPUT_ANIME_NAME")
        elif [[ "$local_search_status" -ne 0 ]]; then
            exit "$local_search_status"
        fi
        [[ -z "${search_results:-}" ]] && print_error "Anime not found for search: $_INPUT_ANIME_NAME"
        # -1 auto-picks instantly when there is only a single match (old behavior);
        # -m lets you TAB-select several seasons/entries when there are more than one
        mapfile -t selected_names < <("$_FZF" -1 -m --header 'TAB to queue multiple seasons, ENTER to confirm' <<< "$search_results")
        [[ ${#selected_names[@]} -eq 0 ]] && print_error "No anime selected."
    else
        download_anime_list
        if [[ -n "${_ANIME_SLUG:-}" ]]; then
            local nm
            nm="$(grep -F "$_ANIME_SLUG" "$_ANIME_LIST_FILE" | tail -1 | remove_slug | sed -E 's/[[:space:]]+$//')"
            [[ -z "$nm" ]] && print_error "Anime slug not found!"
            selected_names=("$nm")
        else
            mapfile -t selected_names < <("$_FZF" -1 -m --header 'TAB to queue multiple, ENTER to confirm' <<< "$(remove_slug < "$_ANIME_LIST_FILE")")
            [[ ${#selected_names[@]} -eq 0 ]] && print_error "No anime selected."
        fi
    fi

    local total=${#selected_names[@]}
    [[ "$total" -gt 1 ]] && print_info "Queued $total seasons/entries for this session."

    local idx=0 name
    for name in "${selected_names[@]}"; do
        idx=$((idx + 1))
        _ANIME_SLUG="$(get_slug_from_name "$name")"
        if [[ -z "${_ANIME_SLUG:-}" ]]; then
            print_warn "[$idx/$total] Could not resolve slug for '$name', skipping."
            continue
        fi

        _ANIME_NAME="$(grep -F "$_ANIME_SLUG" "$_ANIME_LIST_FILE" \
            | tail -1 \
            | remove_slug \
            | sed -E 's/[[:space:]]+$//' \
            | sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g')"

        if [[ "$_ANIME_NAME" == "" ]]; then
            print_warn "[$idx/$total] Anime name not found for '$name'! Skipping."
            continue
        fi

        [[ "$total" -gt 1 ]] && print_info "[$idx/$total] Processing: $_ANIME_NAME"

        # reset per-anime episode spec back to whatever (if anything) was passed with -e
        _ANIME_EPISODE="$_ANIME_EPISODE_ARG"

        # run in a subshell so a failure (curl/jq error under `set -e`, etc.) on one
        # queued anime doesn't kill the whole session; the rest of the queue continues
        ( process_one_anime ) || print_warn "[$idx/$total] Failed while processing '$_ANIME_NAME', continuing with the rest of the queue..."
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
