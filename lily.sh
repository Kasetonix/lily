#!/usr/bin/env bash
progname=${0##*/}
cachedir="${HOME}/.cache/${progname//.sh/}"
nom_lockfile="${cachedir}/nom.lock"
city_cache="${cachedir}/city.cache"
station_cache="${cachedir}/station.cache"
useragent="lily"
ratelimit="1"

c_reset="\033[0m"
c_red="\033[0;31m"
c_green="\033[0;32m"
c_yellow="\033[0;33m"
c_cyan="\033[0;36m"

# Functions
p_info() { echo -e "${c_green}[INFO]:${c_reset} $1"; }
p_error() { echo -e "${c_red}[ ERR]:${c_reset} $1" >&2; }
verbose() { [ -n "$flag_v" ] && p_info "$@"; true; }
error() { p_error "$@"; exit 1; }


clean() {
    [ -n "$spinner_pid" ] && kill "$spinner_pid"
    echo -ne "\e[?25h"
}

# Spinner
display_spinner() {
    local strings=('[|]' '[/]' '[-]' '[\]')

    while true; do
        for str in "${strings[@]}"; do
            echo -ne "${c_cyan}${str}${c_reset} \r"
            sleep 0.33
        done
    done
}

spinner() {
    display_spinner &
    spinner_pid="$!"
    "$@"
}

display_progress() {
    local curr="$1"
    local num="$2"
    local msg="$3"
    local char="#"
    local bar_len="20"
    local perc="$((curr * 100 / num))"
    local bar_num="$((perc * bar_len / 100))"

    local i
    local bar="["
    for ((i = 0; i < bar_num; i++)); do
        bar+="$char"
    done
    for ((i = bar_num; i < bar_len; i++)); do
        bar+=" "
    done
    bar+="]"
    
    line="${c_green}${bar}${c_reset} (${perc}%) ${msg}"
    local padding=""
    for ((i = "${#line}"; i < "COLUMNS"; i++)); do
        padding+=" "
    done

    printf "${c_cyan}%s${c_reset} (%*s%%) %s%s\r" "$bar" 3 "$perc" "$msg" "$padding" 
}

cache_city() {
    verbose "Fetching information on <${city}> from Nominatim."
    [ -f "$nom_lockfile" ] && { error "There is a limit of one request to Nominatim per second!"; }
    touch "$nom_lockfile"
    ( sleep "$ratelimit"; rm "$nom_lockfile" ) &

    verbose "Making an API request."
    nom_out="$(curl -s -H "User-Agent: $useragent" "$api_call")"
    [ "$nom_out" = "[]" ] && error "City not found!"
    latitude="$(jq -r '.[0].lat' <<< "$nom_out")"
    longtitude="$(jq -r '.[0].lon' <<< "$nom_out")"

    verbose "Caching information on <${city}>." 
    verbose "Cached info: <${city}:${latitude}:${longtitude}>."

    echo "${city}:${latitude}:${longtitude}" >> "$city_cache"
}

generate_station_cache() {
    p_info "Caching stations. This may take a while."
    local station_list=("Warszawa" "Poznań" "SuchyLas")
    local station_num="${#station_list[@]}"

    local i="0"
    for station in "${station_list[@]}"; do
        display_progress "$((i+1))" "$station_num" "$station"
        sleep "$ratelimit"
        ((i++))
    done
    echo
}

# hide cursor
echo -ne "\e[?25l"

unset flag_v
unset flag_h
unset spinner_pid
for arg in "$@"; do
    if [[ "$arg" =~ ^(v(erbose)?|-v|--verbose)$ ]]; then
        flag_v="true"
    elif [[ "$arg" =~ ^(h(elp)?|-h|--help)$ ]]; then
        flag_h="true"
    elif [[ -z "$city" ]]; then
        city="$arg"
    fi
done

[ -n "$flag_v" ] && {
    echo -e "${c_green}/// ${c_cyan}${progname}${c_green} was launched with the verbose flag. ///${c_reset}"
    echo "Cache directory:        ${cachedir}"
    echo "City location cache:    ${city_cache}"
    echo "Station location cache: ${station_cache}"
    echo
}

[ -d "$cachedir" ] || { verbose "Creating the cache directory."; mkdir -p "$cachedir"; }
[ -f "$city_cache" ] || { verbose "Creating the city cache file."; touch "$city_cache"; }
[ -f "$station_cache" ] || { verbose "Creating the station cache file."; generate_station_cache; }

trap clean EXIT

city_orig="$city"
[ -z "$city" ] && { error "City name not given!"; }
city="$(echo "$city" | iconv -f utf-8 -t ascii//translit | sed 's/\s//g')"
verbose "City is set to <${city}>."
api_call="https://nominatim.openstreetmap.org/search?city=${city}&countrycodes=pl&limit=1&format=json"

grep -q "$city" "$city_cache" && { verbose "Found <${city}> in cache."; } || { spinner cache_city; }
citydata="$(grep -i -m 1 "$city" "$city_cache")"

IFS=: read -r _ long lat <<< "$citydata"
echo -e "${c_green}${city_orig}${c_reset}: long: ${long} | lat: ${lat}"
