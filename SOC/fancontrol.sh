#!/bin/bash

# Set your high and medium temperature thresholds in degrees Celsius
HIGH_THRESHOLD=65
MEDIUM_THRESHOLD=55

# Set your GPIO pin connected to the fan
GPIO_PIN=45

# Set the spin time in seconds (3 minutes = 180 seconds)
SPIN_TIME=180

# Set the start and end of the quiet hours (22:00 - 08:00)
QUIET_HOURS_START=22
QUIET_HOURS_END=8

# Function to get the temperature
get_temp() {
    vcgencmd measure_temp | awk -F '[=.]' '{print $2}'
}

# Function to execute pinctrl command
pinctrl_cmd() {
    pinctrl $@
}

# Function to get the fan state
get_fan_state() {
    pinctrl_cmd lev $GPIO_PIN
}

# Function to control the fan
control_fan() {
    local state=$1
    local speed=$2
    local fan_state=$(get_fan_state)
    if [[ $fan_state == "1" ]]; then
        pinctrl_cmd set $GPIO_PIN op dl
        pinctrl_cmd set $GPIO_PIN $speed
        echo "Fan set to $speed speed."
        sleep $SPIN_TIME
    fi
}

# Function to turn off the fan
turn_off_fan() {
    local fan_state=$(get_fan_state)
    if [[ $fan_state == "0" ]]; then
        pinctrl_cmd set $GPIO_PIN op dh
        echo "Fan turned off."
    fi
}

# Function to check and control fan based on temperature
check_and_control_fan() {
    local temp=$1
    if (( temp > HIGH_THRESHOLD )); then
        control_fan "on" "a1"
    elif (( temp > MEDIUM_THRESHOLD )); then
        control_fan "on" "a2"
    else
        turn_off_fan
    fi
}

while true; do
    # Get the current hour
    CURRENT_HOUR=$(date +%H)

    # If the current hour is within the quiet hours, sleep until the end of the quiet hours
    if (( CURRENT_HOUR >= QUIET_HOURS_START || CURRENT_HOUR < QUIET_HOURS_END )); then
        echo "Quiet hours. Fan control paused."
        sleep $(( (24 + QUIET_HOURS_END - CURRENT_HOUR) % 24 * 3600 ))
        continue
    fi

    # Get the temperature in degrees Celsius
    TEMP=$(get_temp)

    # Check and control fan based on temperature
    check_and_control_fan $TEMP

    sleep 1
done
