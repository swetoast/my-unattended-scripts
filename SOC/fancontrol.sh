#!/bin/bash

# Configuration
HIGH_THRESHOLD=65
MEDIUM_THRESHOLD=55
GPIO_PIN=45
SPIN_TIME=180
HIGH_SPEED_SPIN_TIME=600
QUIET_HOURS_START=22
QUIET_HOURS_END=8
SLEEP_DURATION=1
HISTORY_DURATION=60

# Initialize the temperature history array
TEMPERATURE_HISTORY=()

# Function to get the temperature
get_temp() {
    vcgencmd measure_temp | awk -F '[=.]' '{print $2}'
}

# Function to check if the Raspberry Pi has overheated
check_overheat() {
    vcgencmd get_throttled | grep -qE "0x4|0x40000" && echo "overheated" || echo "normal"
}

# Function to control the fan
control_fan() {
    local speed=$1
    pinctrl set "$GPIO_PIN" op dl
    pinctrl set "$GPIO_PIN" a"$speed"
    sleep "$([ "$(check_overheat)" == "overheated" ] && echo "$HIGH_SPEED_SPIN_TIME" || echo "$SPIN_TIME")"
}

# Function to turn off the fan
turn_off_fan() {
    pinctrl set "$GPIO_PIN" op dh
}

# Function to check and control fan based on temperature
check_and_control_fan() {
    local temp=$1
    if [[ $(check_overheat) == "overheated" || $temp -gt $HIGH_THRESHOLD ]]; then
        control_fan 2
    elif (( temp > MEDIUM_THRESHOLD )); then
        control_fan 1
    else
        turn_off_fan
    fi
}

# Function to update the temperature history
update_temp_history() {
    local temp=$1
    if [ ${#TEMPERATURE_HISTORY[@]} -ge $HISTORY_DURATION ]; then
        TEMPERATURE_HISTORY=("${TEMPERATURE_HISTORY[@]:1}") # Remove the oldest temperature
    fi
    TEMPERATURE_HISTORY+=("$temp") # Add the new temperature to the end of the array
}

# Function to calculate the median temperature
median_temp() {
    local temps=($(printf '%s\n' "${TEMPERATURE_HISTORY[@]}" | sort -n))
    local count=${#temps[@]}
    if (( count % 2 == 0 )); then
        echo $(( (temps[count/2] + temps[count/2 - 1]) / 2 ))
    else
        echo "${temps[count/2]}"
    fi
}

while true; do
    CURRENT_HOUR=$(date +%-H)
    if (( CURRENT_HOUR >= QUIET_HOURS_START || CURRENT_HOUR < QUIET_HOURS_END )); then
        turn_off_fan
        SLEEP_TIME=$(( (CURRENT_HOUR >= QUIET_HOURS_START ? 24 - CURRENT_HOUR : QUIET_HOURS_END - CURRENT_HOUR) * 3600 - $(date +%-M) * 60 - $(date +%-S) ))
        sleep "$SLEEP_TIME"
        continue
    fi

    TEMP=$(get_temp)
    update_temp_history "$TEMP"

    if [ ${#TEMPERATURE_HISTORY[@]} -ge $HISTORY_DURATION ]; then
        MEDIAN_TEMP=$(median_temp)
        check_and_control_fan "$MEDIAN_TEMP"
    fi

    sleep "$SLEEP_DURATION"
done
