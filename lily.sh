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

c_reset="\e[0m"
c_bold="\e[1m"
c_red="\e[31m"
c_green="\e[32m"
c_yellow="\e[33m"
c_cyan="\e[36m"
c_dim="\e[2m"

# Functions
p_info() { echo -e "${c_green}[INFO]:${c_reset} $1"; }
p_error() { echo -e "\r${c_red}[ ERR]:${c_reset} $1" >&2; }
verbose() { [ "$flag_verbose" = "true" ] && p_info "$@"; true; }
error() { p_error "$@"; exit 1; }

clear_line() {
    local i; local line=""
    for ((i = 0; i < "COLUMNS"; i++)); do
        line+=" "
    done
    echo -ne "\r${line}\r"
}

clean() {
    [ -n "$spinner_pid" ] && { kill "$spinner_pid"; unset spinner_pid; }
    echo -ne "\e[?25h"
}

nom_city_format() {
    echo "$1" | iconv -f utf-8 -t ascii//translit | sed 's/\s/-/g'
}

display_spinner() {
    local strings=('[|]' '[/]' '[-]' '[\]')

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
    printf "${c_cyan}%s${c_reset} (%*s%%) %s%s\r" "$bar" 3 "$perc" "$msg"
}

fetch_city() {
    local fetched_city="$1"
    local city="$2"

    citydata="$(grep -i -m 1 "$fetched_city" "$CITY_CACHE")"
    [ -n "$citydata" ] && { verbose "Found <${fetched_city}> in city cache."; return; }

    display_spinner &
    spinner_pid="$!"

    verbose "Fetching information on <${fetched_city}> from Nominatim."
    [ -z "$fetched_city" ] && { error "\$fetched_city cant be empty";  }
    [ -f "$NOM_LOCKFILE" ] && { error "There is a limit of one request to Nominatim per second!"; }
    :> "$NOM_LOCKFILE"
    ( sleep "$RATELIMIT"; rm "$NOM_LOCKFILE" ) &

    nom_out="$(curl -s -H "User-Agent: $USERAGENT"\
        "https://nominatim.openstreetmap.org/search?q=${fetched_city}&countrycodes=pl&limit=1&format=json")"
    [ "$nom_out" = "[]" ] && error "City not found!"
    latitude="$(jq -r '.[0].lat' <<< "$nom_out")"
    longitude="$(jq -r '.[0].lon' <<< "$nom_out")"

    verbose "Caching information on <${fetched_city}>.\n\tCached info: <${fetched_city}:${latitude}:${longitude}>." 

    echo "${fetched_city}:${latitude}:${longitude}" >> "$CITY_CACHE"
    citydata="${fetched_city}:${latitude}:${longitude}"

    [ -n "$spinner_pid" ] && { kill "$spinner_pid"; unset spinner_pid; }
}

rm_station_cache() {
    rm -r "${STATION_CACHE}"
    clean
    error "Caching stations interrupted; Cache file removed."
}

cache_stations() {
    p_info "Caching stations. This may take a while."
    local imgw_pib_out;
    local station_id
    local station_name
    local station_num

    imgw_pib_out="$(curl -s -H "User-Agent: $USERAGENT" \
        "https://danepubliczne.imgw.pl/api/data/synop")"

    station_num="$(jq -r 'length' <<< "$imgw_pib_out")"
    readarray -t station_id <<< "$(jq -r '.[].id_stacji' <<< "$imgw_pib_out")"
    readarray -t station_name <<< "$(jq -r '.[].stacja' <<< "$imgw_pib_out")"

    trap rm_station_cache INT TERM

    local i; local fetched_city
    for i in "${!station_id[@]}"; do
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

closest_station_data() {
    local citydata="$1"
    IFS=: read -r _ city_lat city_long _ <<< "$citydata"
    local distance; local closest_station_data 
    local min_distance="9223372036854775807" 

    while IFS= read -r line; do
        IFS=: read -r _ st_lat st_long _ <<< "$line"
        distance="$(distsq "$city_lat" "$city_long" "$st_lat" "$st_long")"
        [ "$distance" -lt "$min_distance" ] && { min_distance="$distance"; closest_station_data="$line"; }
    done < "$STATION_CACHE"

    echo "$closest_station_data"
}

fetch_weather() {
    local station_id; local station_name; local date
    local cachedate; local line
    local imgw_pib_out

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
    -v, --verbose  Display additional status information
    -h, --help     Display this message

Locations: script acccepts any location in Poland

When not outputting directly to a terminal (e.g. in a pipeline) this script
outputs raw data in colon-separated csv format:
${c_dim}<station name>:<station id>:<temperature>:<pressure>:<precipitation>:
<humidity>:<wind speed>:<wind direction>${c_reset}
Units are as outputted normally.

Config: You can set the default values of certain variables using a config file located in
${c_dim}\$XDG_CONFIG_DIR/lily.conf${c_reset} or, if ${c_dim}\$XDG_CONFIG_DIR${c_reset} variable is unset, in ${c_dim}~/.config/lily.conf${c_reset}.
The config file format is simple key/value pairs.
Currently supported options are:
    city=<string>          Sets the default city for which the weather is fetched
    flag_verbose=<string>  If true enables verbosity

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
unset flag_verbose
unset flag_h
unset spinner_pid
for arg in "$@"; do
    if [[ "$arg" =~ ^(v(erbose)?|-v|--verbose)$ ]]; then
        flag_verbose="true"
    elif [[ "$arg" =~ ^(h(elp)?|-h|--help)$ ]]; then
        flag_h="true"
    elif [ -z "$city" ]; then
        city="$arg"
    fi
done

# CONFIG FILE
[ -f "$CONFIG" ] && {
    verbose "Reading config file at ${CONFIG//\/home\/kasetonix/\~}"
    declare -A config
    while IFS='=' read -r key val; do
        verbose "${c_green}[CONFIG]:${c_reset} $key=$val"
        config[$key]=$val
    done < "$CONFIG"

    [ -z "$city" ] && city="${config["city"]}"
    [ -z "$flag_verbose" ] && flag_verbose="${config["flag_verbose"]}"
}

# VERBOSE HEADER
[ "$flag_verbose" = "true" ] && {
    echo -e "${c_cyan}${c_bold}${PROGNAME}${c_reset}${c_green} was launched with the verbose flag.${c_reset}"
    echo -e "Cache directory:        ${c_dim}${CACHEDIR}${c_reset}"
    echo -e "City location cache:    ${c_dim}${CITY_CACHE}${c_reset}"
    echo -e "Station location cache: ${c_dim}${STATION_CACHE}${c_reset}"
    echo -e "Weather cache:          ${c_dim}${WEATHER_CACHE}${c_reset}"
    echo
}

# HELP
[ -n "$flag_h" ] && { print_help; exit 0; }

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
[ -t 1 ] || { clean; echo "${st_pretty}:${weatherdata}"; exit 0; }

weatherdata="${weatherdata//n\/a/${c_yellow}n\/a${c_reset}}" # Drawing all n/a's in yellow
IFS=: read -r _ temp press prec hum wind_spd wind_dir <<< "$weatherdata"

if   [ "$wind_dir" -le  "45" ] || [ "$wind_dir" -ge "315" ]; then wind_dir="${c_dim}↓${c_reset} $wind_dir"
elif [  "45" -lt "$wind_dir" ] && [ "$wind_dir" -le "135" ]; then wind_dir="${c_dim}←${c_reset} $wind_dir"
elif [ "135" -lt "$wind_dir" ] && [ "$wind_dir" -le "225" ]; then wind_dir="${c_dim}↑${c_reset} $wind_dir"
elif [ "225" -lt "$wind_dir" ] && [ "$wind_dir" -le "315" ]; then wind_dir="${c_dim}→${c_reset} $wind_dir"
fi

[ "$flag_verbose" = "true" ] && echo
echo -e "${c_green}${c_bold}Station:${c_reset} ${st_pretty} | ${c_green}${c_bold}Time:${c_reset} $(printf '%(%F %R)T\n' "-1")"

echo -e "${c_cyan}Temperature:${c_reset}|${temp}|${c_dim}°C${c_reset}
${c_cyan}Pressure:${c_reset}|${press}|${c_dim}hPa${c_reset}
${c_cyan}Precipitation:${c_reset}|${prec}|${c_dim}mm${c_reset}
${c_cyan}Humidity:${c_reset}|${hum}|${c_dim}%${c_reset}
${c_cyan}Wind speed:${c_reset}|${wind_spd}|${c_dim}km/h${c_reset}
${c_cyan}Wind direction:${c_reset}|${wind_dir}|${c_dim}°${c_reset}" | \
    column -t -s '|' -o ' ' -C title,left -C data,right -C unit,left
