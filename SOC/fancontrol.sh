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

# Initialize the temperature history array
TEMPERATURE_HISTORY=()

# Function to get the temperature
get_temp() {
    vcgencmd measure_temp | awk -F '[=.]' '{print $2}'
}

# Function to check if the Raspberry Pi has overheated
check_overheat() {
    local throttled=$(vcgencmd get_throttled)
    if [[ $throttled == *"0x4"* || $throttled == *"0x40000"* ]]; then
        echo "overheated"
    else
        echo "normal"
    fi
}

# Function to execute pinctrl command
pinctrl_cmd() {
    pinctrl $@
}

# Function to get the fan speed
get_fan_speed() {
    local speed=$(pinctrl get $GPIO_PIN | grep -oE "(lo|hi)")
    if [[ $speed == "hi" ]]; then
        echo "high"  # Fan is running at high speed
    elif [[ $speed == "lo" ]]; then
        echo "low"   # Fan is running at low speed
    fi
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
    local fan_speed=$(get_fan_speed)
    if [[ $fan_state != $state || $fan_speed != $speed ]]; then
        pinctrl set $GPIO_PIN op dl
        if [[ $speed == "high" ]]; then
            pinctrl set $GPIO_PIN a2
        elif [[ $speed == "low" ]]; then
            pinctrl set $GPIO_PIN a1
        fi
        echo "Fan set to $(get_fan_speed) speed."
        if [[ $(check_overheat) == "overheated" ]]; then
            sleep $HIGH_SPEED_SPIN_TIME
        else
            sleep $SPIN_TIME
        fi
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
    if [[ $(check_overheat) == "overheated" ]]; then
        control_fan "on" "high"
    elif (( temp > HIGH_THRESHOLD )); then
        control_fan "on" "high"
    elif (( temp > MEDIUM_THRESHOLD )); then
        control_fan "on" "low"
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

# Function to calculate the average temperature
average_temp() {
    local sum=0
    for temp in "${TEMPERATURE_HISTORY[@]}"; do
        let sum+=$temp
    done
    echo $((sum / ${#TEMPERATURE_HISTORY[@]}))
}

while true; do
    # Get the current hour
    CURRENT_HOUR=$(date +%-H)

    # If the current hour is within the quiet hours, turn off the fan and sleep until the end of the quiet hours
    if (( CURRENT_HOUR >= QUIET_HOURS_START || CURRENT_HOUR < QUIET_HOURS_END )); then
        turn_off_fan
        sleep $(( (24 + QUIET_HOURS_END - CURRENT_HOUR) % 24 * 3600 ))
        continue
    fi

    # Get the temperature in degrees Celsius
    TEMP=$(get_temp)

    # Update the temperature history
    update_temp_history $TEMP

    # If the temperature history array has reached its maximum size
    if [ ${#TEMPERATURE_HISTORY[@]} -ge $HISTORY_DURATION ]; then
        # Calculate the average temperature
        AVG_TEMP=$(average_temp)

        # Check and control fan based on average temperature
        check_and_control_fan $AVG_TEMP
    fi

    sleep 1
done
