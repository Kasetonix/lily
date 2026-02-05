#!/usr/bin/env bash
PROGNAME=${0##*/}
CACHEDIR="${HOME}/.cache/lily"
CONFIGDIR="${XDG_CONFIG_DIR:-$HOME/.config}"
CONFIG="${CONFIGDIR}/lily.conf"
NOM_LOCKFILE="${CACHEDIR}/nom.lock"
CITY_CACHE="${CACHEDIR}/city.cache"
STATION_CACHE="${CACHEDIR}/station.cache"
WEATHER_CACHE="${CACHEDIR}/weather.cache"
USERAGENT="lily"
RATELIMIT="1"
FETCHED_INFO='.temperatura,.cisnienie,.suma_opadu,.wilgotnosc_wzgledna,.predkosc_wiatru,.kierunek_wiatru'

# Functions
p_info() { echo -e "${c_green}[INFO]:${c_reset} $1"; }
p_error() { echo -e "\r${c_red}[ ERR]:${c_reset} $1" >&2; }
verbose() { [ "${opts["flag_verbose"]}" = "true" ] && p_info "$@"; true; }
error() { p_error "$@"; exit 1; }

clean() {
    [ -n "$spinner_pid" ] && { kill "$spinner_pid"; unset spinner_pid; }
    echo -ne "\e[?25h"
}

# From "Pure Bash Bible" by Dylan Araps
# https://github.com/dylanaraps/pure-bash-bible?tab=readme-ov-file#trim-all-white-space-from-string-and-truncate-spaces
trim_all() {
    set -f
    set -- $*
    printf '%s\n' "$*"
    set +f
}

nom_city_format() {
    city="$(trim_all "$1")"
    city="${city// /-}"
    iconv -f utf-8 -t ascii//translit <<< "${city,,}"
}

display_spinner() {
    local strings

    strings=('[|]' '[/]' '[-]' '[\]')
    while true; do
        for str in "${strings[@]}"; do
            echo -ne "${c_cyan}${str}${c_reset} \r"
            sleep 0.0625
        done
    done
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
    local curr num msg char bar_len perc bar_num i bar
    curr="$1"; num="$2"; msg="$3"
    char="#"; bar_len="33"
    perc="$((curr * 100 / num))"; bar_num="$((perc * bar_len / 100))"

    bar="["
    for ((i = 0; i < bar_num; i++)); do
        bar+="$char"
    done
    for ((i = bar_num; i < bar_len; i++)); do
        bar+=" "
    done
    bar+="]"
    
    printf "\r\e[K${c_cyan}%s${c_reset} (%*s%%) %s%s\r" "$bar" 3 "$perc" "$msg"
}

fetch_city() {
    local fetched_city city nom_out jq_out lat long
    fetched_city="$1" city="$2"

    citydata="$(grep -i -m 1 "$fetched_city" "$CITY_CACHE")"
    [ -n "$citydata" ] && { verbose "Found <${fetched_city}> in city cache."; return; }

    display_spinner &
    spinner_pid="$!"

    verbose "Fetching information on <${fetched_city}> from Nominatim."
    [ -z "$fetched_city" ] && { error "\$fetched_city cant be empty";  }
    [ -f "$NOM_LOCKFILE" ] && { error "There is a limit of one request to Nominatim per second!"; }
    :> "$NOM_LOCKFILE"
    ( sleep "$RATELIMIT"; rm "$NOM_LOCKFILE" ) &

    nom_out="$(curl -s -H "User-Agent: $USERAGENT" \
        "https://nominatim.openstreetmap.org/search?q=${fetched_city}&countrycodes=pl&limit=1&format=json")"
    [ "$nom_out" = "[]" ] && error "City not found!"
    jq_out="$(jq -r '.[0].lat,.[0].lon' <<< "$nom_out")"
    read -r lat long <<< "${jq_out//$'\n'/ }"

    verbose "Caching information on <${fetched_city}>.\n\tCached info: <${fetched_city}:${lat}:${long}>." 

    echo "${fetched_city}:${lat}:${long}" >> "$CITY_CACHE"
    citydata="${fetched_city}:${lat}:${long}"

    [ -n "$spinner_pid" ] && { kill "$spinner_pid"; unset spinner_pid; }
}

rm_station_cache() {
    rm -r "${STATION_CACHE}"
    clean
    error "Caching stations interrupted; Cache file removed."
}

cache_stations() {
    p_info "Caching stations. This may take a while."
    local imgw_pib_out station_id station_name station_num lat long
    declare -a station_id station_name

    imgw_pib_out="$(curl -s -H "User-Agent: $USERAGENT" \
        "https://danepubliczne.imgw.pl/api/data/synop")"

    station_num="$(jq -r 'length' <<< "$imgw_pib_out")"
    readarray -t station_id <<< "$(jq -r '.[].id_stacji' <<< "$imgw_pib_out")"
    readarray -t station_name <<< "$(jq -r '.[].stacja' <<< "$imgw_pib_out")"

    trap rm_station_cache INT TERM

    local i fetched_city
    for i in "${!station_id[@]}"; do
        fetched_city="$(nom_city_format "${station_name[$i]}")"
        ( sleep "$RATELIMIT" ) &
        nom_out="$(curl -s -H "User-Agent: $USERAGENT" \
            "https://nominatim.openstreetmap.org/search?q=${fetched_city}&countrycodes=pl&limit=1&format=json")"
        [ "$nom_out" = "[]" ] && error "Station city not found!"
        jq_out="$(jq -r '.[0].lat,.[0].lon' <<< "$nom_out")"
        read -r lat long <<< "${jq_out//$'\n'/ }"

        verbose "Cached info: ${station_id[$i]}:${lat}:${long}:${station_name[$i]}"
        echo "${station_id[$i]}:${lat}:${long}:${station_name[$i]}" >> "$STATION_CACHE"
        display_progress "$((i+1))" "$station_num" "${station_name[$i]}"
        wait
    done

    echo -e "\r\e[K\r"
    p_info "Caching stations done."

    trap - INT TERM
}

closest_station_data() {
    local citydata city_lat city_long st_lat st_long \
        closest_station_data distance min_distance
    citydata="$1"; min_distance="9223372036854775807"
    IFS=: read -r _ city_lat city_long _ <<< "$citydata"

    while IFS= read -r line; do
        IFS=: read -r _ st_lat st_long _ <<< "$line"
        distance="$(distsq "$city_lat" "$city_long" "$st_lat" "$st_long")"
        [ "$distance" -lt "$min_distance" ] && { min_distance="$distance"; closest_station_data="$line"; }
    done < "$STATION_CACHE"

    echo "$closest_station_data"
}

fetch_weather() {
    local station_id station_name date cachedate line imgw_pib_out

    station_id="$1"
    station_name="$2"
    date="$3"

    mapfile -tn '1' line < "$WEATHER_CACHE"
    cachedate="${line[0]}"

    if [ "$date" = "$cachedate" ]; then
        weatherdata="$(grep -i -m 1 "$station_id" "$WEATHER_CACHE")"
        [ -n "$weatherdata" ] && { verbose "Found cached weather information from station <${station_name}>."; return; }
    else
        if [ -n "$cachedate" ]; then verbose "Remaking cache." else verbose "Creating weather cache."; fi
        echo "$date" > "$WEATHER_CACHE"
        cachedate="$date"
    fi

    display_spinner &
    spinner_pid="$!"

    verbose "Fetching weather information from station <${station_name}>."
    imgw_pib_out="$(curl -s -H "User-Agent: $USERAGENT" \
        "https://danepubliczne.imgw.pl/api/data/synop/id/${station_id}")"
    weatherdata="$(jq -r "$FETCHED_INFO" <<< "$imgw_pib_out")"
    weatherdata="${station_id}:${weatherdata//$'\n'/:}"
    weatherdata="${weatherdata//null/n\/a}"

    echo "$weatherdata" >> "$WEATHER_CACHE"
    [ -n "$spinner_pid" ] && { kill "$spinner_pid"; unset spinner_pid; }
}

print_help() {
echo -e "${c_cyan}${c_bold}lily.sh${c_reset} - shell script for fetching weather information.
USAGE: $PROGNAME [OPTION] LOCATION

Options:
    -h, --help       Display this message
    -v, --verbose    Display additional status information
    -r, --raw        Always display output in colon-separated csv format
    -f, --formatted  Always display formatted output, even through a pipe
    -n, --no-color   Disable output color

Locations: script acccepts any location in Poland.

When not outputting directly to a terminal (e.g. in a pipeline) this script
outputs raw data in colon-separated csv format:
${c_dim}<station name>:<station id>:<temperature>:<pressure>:<precipitation>:
<humidity>:<wind speed>:<wind direction>${c_reset}
Units are as outputted normally.

Config: You can set the default values of certain variables using a config file located in
${c_dim}\$XDG_CONFIG_DIR/lily.conf${c_reset} or, if ${c_dim}\$XDG_CONFIG_DIR${c_reset} variable is unset, in ${c_dim}~/.config/lily.conf${c_reset}.
The config file format is simple key/value pairs.
Currently supported options are:
    city=<string>            Sets the default city for which the weather is fetched
    flag_verbose=<string>    If true acts like --verbose
    flag_raw=<string>        If true acts like --raw
    flag_formatted=<string>  If true acts like --formatted
    flag_no_color=<string>   If true acts like --no-color

Data attributions:
${c_dim}Geocoding data from OpenStreetMap/Nominatim
Źródłem pochodzenia danych jest Instytut Meteorologii i Gospodarki Wodnej - Państwowy Instytut Badawczy.${c_reset}"
}

# INIT
trap clean EXIT
echo -ne "\e[?25l" # hide cursor
declare citydata
declare weatherdata

# CMD ARGUMENTS
unset spinner_pid
declare unknown_arg=""
declare -A opts
for arg in "$@"; do
    if   [[ "$arg" =~ ^(v(erbose)?|-v|--verbose)$ ]]; then opts["flag_verbose"]="true"
    elif [[ "$arg" =~ ^(h(elp)?|-h|--help)$ ]]; then opts["flag_help"]="true"
    elif [[ "$arg" =~ ^(r(aw)?|-r|--raw)$ ]]; then opts["flag_raw"]="true"
    elif [[ "$arg" =~ ^(f(ormatted)?|-f|--formatted)$ ]]; then opts["flag_formatted"]="true"
    elif [[ "$arg" =~ ^(nc?(olor)?|-n|--no-color)$ ]]; then opts["flag_no_color"]="true"
    elif [[ "$arg" =~ ^-.*$ ]]; then [ -z "$unknown_arg" ] && unknown_arg="${arg}" || unknown_arg="${arg}, ${unknown_arg}"
    elif [ -z "$city" ]; then city="$arg"
    else [ -z "$unknown_arg" ] && unknown_arg="${arg}" || unknown_arg="${arg}, ${unknown_arg}"
    fi
done

# CONFIG FILE
[ -f "$CONFIG" ] && {
    declare -A config
    while IFS='=' read -r key val; do
        config[$key]=$val
    done < "$CONFIG"

    [ -z "$city" ] && city="${config["city"]}"
    [ -z "${opts["flag_verbose"]}" ] && opts["flag_verbose"]="${config["flag_verbose"]}"
    [ -z "${opts["flag_raw"]}" ] && opts["flag_raw"]="${config["flag_raw"]}"
    [ -z "${opts["flag_formatted"]}" ] && opts["flag_formatted"]="${config["flag_formatted"]}"
    [ -z "${opts["flag_no_color"]}" ] && opts["flag_no_color"]="${config["flag_no_color"]}"
}

# COLOR HANLDING 
declare c_reset="" c_bold="" c_red="" c_green="" c_yellow="" c_cyan="" c_dim=""
[ "${opts["flag_no_color"]}" != "true" ] && { 
    c_reset="\e[0m"
    c_bold="\e[1m"
    c_dim="\e[2m"
    c_red="\e[31m"
    c_green="\e[32m"
    c_yellow="\e[33m"
    c_cyan="\e[36m"
}

# ARGUMENT VALIDATION
[ -z "$unknown_arg" ] || { error "Unknown arguments: ${unknown_arg//,$/}"; }

# VERBOSE HEADER
[ "${opts["flag_verbose"]}" = "true" ] && {
    echo -e "${c_cyan}${c_bold}${PROGNAME}${c_reset}${c_green} was launched with the verbose flag.${c_reset}"
    echo -e "City location cache:    ${c_dim}${CITY_CACHE//$HOME/\~}${c_reset}"
    echo -e "Station location cache: ${c_dim}${STATION_CACHE//$HOME/\~}${c_reset}"
    echo -e "Weather cache:          ${c_dim}${WEATHER_CACHE//$HOME/\~}${c_reset}"
    echo -e "Config file:            ${c_dim}${CONFIG//$HOME/\~}${c_reset}\n"
}

# DISPLAYING OPTIONS WHEN RUN WITH --VERBOSE
[ "${opts["flag_verbose"]}" = "true" ] && {
    p_info "Used options:"
    for key in "${!opts[@]}"; do
        [ -n "${opts["$key"]}" ] && p_info "${key}=${opts["$key"]}"
    done
    echo
}

# HELP
[ -n "${opts["flag_help"]}" ] && { print_help; exit 0; }

# DIR/FILE INIT 
[ -d "$CACHEDIR" ]      || { verbose "Creating the cache directory."; mkdir -p "$CACHEDIR"; }
[ -f "$STATION_CACHE" ] || { verbose "Creating the station cache file."; cache_stations; }
[ -f "$CITY_CACHE" ]    || { verbose "Creating the city cache file."; :> "$CITY_CACHE"; }
[ -f "$WEATHER_CACHE" ] || { :> "$WEATHER_CACHE"; }

# HANDLING THE CITY ARGUMENT
[ -z "$city" ] && { error "City name not given!"; }
city_f="$(nom_city_format "$city")"
verbose "City is set to <${city_f}>."

# FETCHING CITY
fetch_city "$city_f" "$city"

# FETCHING CLOSEST STATION
IFS=: read -r station _ _ st_pretty <<< "$(closest_station_data "$citydata")"
verbose "Closest station found is <${st_pretty}>."

# FETCHING WEATHER
date="$(printf '%(%F:%H)T\n' "-1")"
fetch_weather "$station" "$st_pretty" "$date"

# OUTPUT
# if not outputting to a terminal output raw data 
[ "${opts["flag_formatted"]}" != "true" ] && [ ! -t 1 ] || [ "${opts["flag_raw"]}" = "true" ] && \
    { clean; echo "${st_pretty}:${weatherdata}"; exit 0; }

weatherdata="${weatherdata//n\/a/${c_yellow}n\/a${c_reset}}" # Drawing all n/a's in yellow
IFS=: read -r _ temp press prec hum wind_spd wind_dir <<< "$weatherdata"

if   [ "$wind_dir" -le  "45" ] || [ "$wind_dir" -ge "315" ]; then wind_dir="${c_dim}↓${c_reset} $wind_dir"
elif [  "45" -lt "$wind_dir" ] && [ "$wind_dir" -le "135" ]; then wind_dir="${c_dim}←${c_reset} $wind_dir"
elif [ "135" -lt "$wind_dir" ] && [ "$wind_dir" -le "225" ]; then wind_dir="${c_dim}↑${c_reset} $wind_dir"
elif [ "225" -lt "$wind_dir" ] && [ "$wind_dir" -le "315" ]; then wind_dir="${c_dim}→${c_reset} $wind_dir"
fi

[ "${opts["flag_verbose"]}" = "true" ] && echo
echo -e "${c_green}${c_bold}Station:${c_reset} ${st_pretty} | ${c_green}${c_bold}Time:${c_reset} $(printf '%(%F %R)T\n' "-1")"

echo -e "${c_cyan}Temperature:${c_reset}|${temp}|${c_dim}°C${c_reset}
${c_cyan}Pressure:${c_reset}|${press}|${c_dim}hPa${c_reset}
${c_cyan}Precipitation:${c_reset}|${prec}|${c_dim}mm${c_reset}
${c_cyan}Humidity:${c_reset}|${hum}|${c_dim}%${c_reset}
${c_cyan}Wind speed:${c_reset}|${wind_spd}|${c_dim}km/h${c_reset}
${c_cyan}Wind direction:${c_reset}|${wind_dir}|${c_dim}°${c_reset}" | \
    column -t -s '|' -o ' ' -C title,left -C data,right -C unit,left
