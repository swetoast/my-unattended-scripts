#!/bin/bash

# Set your high and medium temperature thresholds in degrees Celsius
HIGH_THRESHOLD=65
MEDIUM_THRESHOLD=55

# Set your GPIO pin connected to the fan
GPIO_PIN=45

# Set the spin time in seconds (3 minutes = 180 seconds)
SPIN_TIME=180

# Set the extended spin time for high speeds (10 minutes = 600 seconds)
HIGH_SPEED_SPIN_TIME=600

# Set the start and end of the quiet hours (22:00 - 08:00)
QUIET_HOURS_START=22
QUIET_HOURS_END=8

# Define the duration for which temperature data is stored (in seconds)
HISTORY_DURATION=60

# Initialize the maximum history duration
MAX_HISTORY_DURATION=180

# Initialize the temperature history array
TEMPERATURE_HISTORY=()

# Initialize the sleep duration
SLEEP_DURATION=1

# Function to get the temperature
get_temp() {
    local temp
    temp=$(vcgencmd measure_temp | awk -F '[=.]' '{print $2}')
    echo "$temp"
}

# Function to check if the Raspberry Pi has overheated
check_overheat() {
    local throttled
    throttled=$(vcgencmd get_throttled)
    if [[ $throttled == *"0x4"* || $throttled == *"0x40000"* ]]; then
        echo "overheated"
    else
        echo "normal"
    fi
}

# Function to execute pinctrl command
pinctrl_cmd() {
    pinctrl "$@"
}

# Function to get the fan speed
get_fan_speed() {
    local speed
    speed=$(pinctrl get "$GPIO_PIN" | grep -oE "(lo|hi)")
    if [[ $speed == "hi" ]]; then
        echo "high"  # Fan is running at high speed
    elif [[ $speed == "lo" ]]; then
        echo "low"   # Fan is running at low speed
    fi
}

# Function to get the fan state
get_fan_state() {
    pinctrl_cmd lev "$GPIO_PIN"
}

# Function to control the fan
control_fan() {
    local state=$1
    local speed=$2
    local temp=$3
    local fan_state
    fan_state=$(get_fan_state)
    local fan_speed
    fan_speed=$(get_fan_speed)
    if [[ "$fan_state" != "$state" || "$fan_speed" != "$speed" ]]; then
        pinctrl set "$GPIO_PIN" op dl
        if [[ $speed == "high" ]]; then
            pinctrl set "$GPIO_PIN" a2
        elif [[ $speed == "low" ]]; then
            pinctrl set "$GPIO_PIN" a1
        fi
        echo "Fan set to $(get_fan_speed) speed, due to temperature at $temp°C."
        if [[ $(check_overheat) == "overheated" ]]; then
            sleep "$HIGH_SPEED_SPIN_TIME"
        else
            sleep "$SPIN_TIME"
        fi
    fi
}

# Function to turn off the fan
turn_off_fan() {
    local fan_state
    fan_state=$(get_fan_state)
    if [[ $fan_state == "0" ]]; then
        pinctrl_cmd set "$GPIO_PIN" op dh
        echo "Fan turned off."
    fi
}

# Function to check and control fan based on temperature
check_and_control_fan() {
    local temp=$1
    if [[ $(check_overheat) == "overheated" ]]; then
        control_fan "on" "high" "$temp"
    elif (( temp > HIGH_THRESHOLD )); then
        control_fan "on" "high" "$temp"
    elif (( temp > MEDIUM_THRESHOLD )); then
        control_fan "on" "low" "$temp"
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

# Function to adjust history duration based on temperature stability
adjust_history_duration() {
    local temp=$1
    if (( temp > HIGH_THRESHOLD || temp < MEDIUM_THRESHOLD )); then
        HISTORY_DURATION=60
    else
        HISTORY_DURATION=$MAX_HISTORY_DURATION
    fi
}

while true; do
    # Get the current hour
    CURRENT_HOUR=$(date +%-H)

    # If the current hour is within the quiet hours, turn off the fan and sleep until the end of the quiet hours
    if (( CURRENT_HOUR >= QUIET_HOURS_START || CURRENT_HOUR < QUIET_HOURS_END )); then
        turn_off_fan
        if (( CURRENT_HOUR >= QUIET_HOURS_START )); then
            # Calculate the remaining time until midnight
            SECONDS_UNTIL_MIDNIGHT=$(( (24 - CURRENT_HOUR) * 3600 - $(date +%-M) * 60 - $(date +%-S) ))
            # Calculate the remaining time from midnight to the end of quiet hours
            SECONDS_UNTIL_END_OF_QUIET_HOURS=$(( QUIET_HOURS_END * 3600 ))
            # Total sleep time
            SLEEP_TIME=$(( SECONDS_UNTIL_MIDNIGHT + SECONDS_UNTIL_END_OF_QUIET_HOURS ))
        else
            # Calculate the remaining time until the end of quiet hours
            SECONDS_UNTIL_END_OF_QUIET_HOURS=$(( (QUIET_HOURS_END - CURRENT_HOUR) * 3600 - $(date +%-M) * 60 - $(date +%-S) ))
            SLEEP_TIME=$SECONDS_UNTIL_END_OF_QUIET_HOURS
        fi
        sleep "$SLEEP_TIME"
        continue
    fi

    # Get the temperature in degrees Celsius
    TEMP=$(get_temp)

    # Adjust history duration based on temperature stability
    adjust_history_duration "$TEMP"

    # Update the temperature history
    update_temp_history "$TEMP"

    # If the temperature history array has reached its maximum size
    if [ ${#TEMPERATURE_HISTORY[@]} -ge $HISTORY_DURATION ]; then
        # Calculate the median temperature
        MEDIAN_TEMP=$(median_temp)

        # Check and control fan based on median temperature
        check_and_control_fan "$MEDIAN_TEMP"
    fi

    # Adjust sleep duration based on temperature stability
    if (( TEMP > HIGH_THRESHOLD || TEMP < MEDIUM_THRESHOLD )); then
        SLEEP_DURATION=1
    else
        SLEEP_DURATION=5
    fi

    sleep "$SLEEP_DURATION"
done
