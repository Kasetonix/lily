#!/usr/bin/env bash
PROGNAME=${0##*/}
CACHEDIR="${HOME}/.cache/lily"
NOM_LOCKFILE="${CACHEDIR}/nom.lock"
CITY_CACHE="${CACHEDIR}/city.cache"
STATION_CACHE="${CACHEDIR}/station.cache"
USERAGENT="lily"
RATELIMIT="1"

c_reset="\033[0m"
c_red="\033[0;31m"
c_green="\033[0;32m"
c_cyan="\033[0;36m"

# Functions
p_info() { echo -e "${c_green}[INFO]:${c_reset} $1"; }
p_error() { echo -e "\r${c_red}[ ERR]:${c_reset} $1" >&2; }
verbose() { [ -n "$flag_v" ] && p_info "$@"; true; }
error() { p_error "$@"; exit 1; }

clear_line() {
    local i; local line=""
    for ((i = 0; i < "COLUMNS"; i++)); do
        line+=" "
    done
    echo -ne "\r$line\r"
}

clean() {
    [ -n "$spinner_pid" ] && kill "$spinner_pid"
    echo -ne "\e[?25h"
}

nom_city_format() {
    echo "$1" | iconv -f utf-8 -t ascii//translit | sed 's/\s/-/g'
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

distsq() {
    local city_coord_y="${1//./}"
    local city_coord_x="${2//./}"
    local station_coord_y="${3//./}"
    local station_coord_x="${4//./}"
    local lat_distance=$((city_coord_y - station_coord_y))
    local long_distance="$((city_coord_x - station_coord_x))"

    echo "$(((lat_distance/100)**2 + (long_distance/100)**2))"
}

display_progress() {
    local curr="$1"; local num="$2"; local msg="$3"
    local char="#"; local bar_len="33"
    local perc="$((curr * 100 / num))"
    local bar_num="$((perc * bar_len / 100))"

    local i; local bar="["
    for ((i = 0; i < bar_num; i++)); do
        bar+="$char"
    done
    for ((i = bar_num; i < bar_len; i++)); do
        bar+=" "
    done
    bar+="]"
    
    clear_line
    printf "${c_cyan}%s${c_reset} (%*s%%) %s%s\r" "$bar" 3 "$perc" "$msg" "$padding" 
}

cache_city() {
    local fetched_city="$1"
    local city_pretty="$2"
    verbose "Fetching information on <${fetched_city}> from Nominatim."
    [ -z "$fetched_city" ] && { error "\$fetched_city cant be empty";  }
    [ -f "$NOM_LOCKFILE" ] && { error "There is a limit of one request to Nominatim per second!"; }
    touch "$NOM_LOCKFILE"
    ( sleep "$RATELIMIT"; rm "$NOM_LOCKFILE" ) &

    nom_out="$(curl -s -H "User-Agent: $USERAGENT"\
        "https://nominatim.openstreetmap.org/search?q=${fetched_city}&countrycodes=pl&limit=1&format=json")"
    [ "$nom_out" = "[]" ] && error "City not found!"
    latitude="$(jq -r '.[0].lat' <<< "$nom_out")"
    longitude="$(jq -r '.[0].lon' <<< "$nom_out")"

    verbose "Caching information on <${fetched_city}>.\n\tCached info: <${fetched_city}:${latitude}:${longitude}>." 

    echo "${fetched_city}:${latitude}:${longitude}" >> "$CITY_CACHE"
}

rm_station_cache() {
    rm -r "${STATION_CACHE}"
    clean
    error "Caching stations interrupted; Cache file removed."
}

cache_stations() {
    p_info "Caching stations. This may take a while."
    local imgw_pib_out="$(curl -s -H "User-Agent: $USERAGENT" \
        "https://danepubliczne.imgw.pl/api/data/synop")"

    local station_id
    local station_name
    local station_num="$(jq -r 'length' <<< "$imgw_pib_out")"
    readarray -t station_id <<< "$(jq -r '.[].id_stacji' <<< "$imgw_pib_out")"
    readarray -t station_name <<< "$(jq -r '.[].stacja' <<< "$imgw_pib_out")"

    trap rm_station_cache INT TERM

    local i; local fetched_city
    for ((i = 0; i < station_num; i++)); do
        fetched_city="$(nom_city_format "${station_name[$i]}")"
        ( sleep "$RATELIMIT" ) &
        nom_out="$(curl -s -H "User-Agent: $USERAGENT"\
            "https://nominatim.openstreetmap.org/search?q=${fetched_city}&countrycodes=pl&limit=1&format=json")"
        [ "$nom_out" = "[]" ] && error "Station city not found!"
        latitude="$(jq -r '.[0].lat' <<< "$nom_out")"
        longitude="$(jq -r '.[0].lon' <<< "$nom_out")"

        verbose "Cached info: ${station_id[$i]}:${latitude}:${longitude}:${station_name[$i]}"
        echo "${station_id[$i]}:${latitude}:${longitude}:${station_name[$i]}" >> "$STATION_CACHE"
        display_progress "$((i+1))" "$station_num" "${station_name[$i]}"
        wait
    done
    clear_line
    p_info "Caching stations done."

    trap - INT TERM
}

closest_station() {
    local citydata="$1"
    IFS=: read -r _ city_lat city_long _ <<< "$citydata"
    local distance; local closest_station_id
    local min_distance="9223372036854775807" 

    while IFS= read -r line; do
        IFS=: read -r st_id st_lat st_long _ <<< "$line"
        distance="$(distsq $city_lat $city_long $st_lat $st_long)"
        [ "$distance" -lt "$min_distance" ] && { min_distance="$distance"; closest_station_id="$st_id"; }
    done < "$STATION_CACHE"

    echo "$closest_station_id"
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
        city_pretty="$arg"
    fi
done

[ -n "$flag_v" ] && {
    echo -e "${c_green}/// ${c_cyan}${PROGNAME}${c_green} was launched with the verbose flag. ///${c_reset}"
    echo "Cache directory:        ${CACHEDIR}"
    echo "City location cache:    ${CITY_CACHE}"
    echo "Station location cache: ${STATION_CACHE}"
    echo
}

trap clean EXIT

[ -d "$CACHEDIR" ] || { verbose "Creating the cache directory."; mkdir -p "$CACHEDIR"; }

[ -z "$city_pretty" ] && { error "City name not given!"; }
city="$(nom_city_format "$city_pretty")"
verbose "City is set to <${city}>."

[ -f "$STATION_CACHE" ] || { verbose "Creating the station cache file."; cache_stations; }

grep -q "$city" "$CITY_CACHE" && { verbose "Found <${city}> in city cache."; } || { spinner cache_city "$city" "$city_pretty"; }

citydata="$(grep -i -m 1 "$city" "$CITY_CACHE")"
stationdata="$(grep "$(closest_station "$citydata")" "$STATION_CACHE")"
IFS=: read -r city city_lat city_long <<< "$citydata"
IFS=: read -r station st_lat st_long st_pretty <<< "$stationdata"

echo -e "${c_cyan}CITY:    ${c_green}${city_pretty}${c_reset}: ${city_long} : ${city_lat} (<$city>)"
echo -e "${c_cyan}STATION: ${c_green}${st_pretty}${c_reset}: ${st_long} : ${st_lat}"
