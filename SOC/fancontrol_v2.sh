#!/bin/bash

# Set your maximum, high and medium temperature thresholds in degrees Celsius
MAX_THRESHOLD=80
DEFAULT_HIGH_THRESHOLD=65
DEFAULT_MEDIUM_THRESHOLD=55

# Set the adjustment value
ADJUSTMENT=5

# Set the reset interval in seconds (1 hour = 3600 seconds)
RESET_INTERVAL=3600

# Initialize the temperature history array
TEMPERATURE_HISTORY=()

# Initialize thresholds
high_threshold=$DEFAULT_HIGH_THRESHOLD
medium_threshold=$DEFAULT_MEDIUM_THRESHOLD

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

# Function to calculate the median temperature
median_temp() {
    local temps=($(printf '%d\n' "${TEMPERATURE_HISTORY[@]}" | sort -n))
    local count=${#temps[@]}
    if (( count % 2 == 0 )); then
        echo $(( (temps[count/2] + temps[count/2 - 1]) / 2 ))
    else
        echo ${temps[count/2]}
    fi
}

while true; do
    # Get the current temperature
    TEMP=$(get_temp)

    # Update the temperature history
    TEMPERATURE_HISTORY+=("$TEMP")

    # If the temperature history array has reached its maximum size
    if [ ${#TEMPERATURE_HISTORY[@]} -ge $HISTORY_DURATION ]; then
        # Calculate the median temperature
        MEDIAN_TEMP=$(median_temp)

        # Adjust thresholds based on median temperature
        if (( MEDIAN_TEMP > high_threshold && high_threshold < MAX_THRESHOLD )); then
            high_threshold=$((high_threshold + ADJUSTMENT))
        elif (( MEDIAN_TEMP < high_threshold )); then
            high_threshold=$((high_threshold - ADJUSTMENT))
        fi

        if (( MEDIAN_TEMP > medium_threshold && medium_threshold < MAX_THRESHOLD )); then
            medium_threshold=$((medium_threshold + ADJUSTMENT))
        elif (( MEDIAN_TEMP < medium_threshold )); then
            medium_threshold=$((medium_threshold - ADJUSTMENT))
        fi

        # Ensure thresholds do not exceed maximum
        high_threshold=$(( high_threshold > MAX_THRESHOLD ? MAX_THRESHOLD : high_threshold ))
        medium_threshold=$(( medium_threshold > MAX_THRESHOLD ? MAX_THRESHOLD : medium_threshold ))

        # Check and control fan based on new thresholds
        check_and_control_fan $MEDIAN_TEMP $high_threshold $medium_threshold

        # Reset thresholds after a certain interval
        if (( SECONDS % RESET_INTERVAL == 0 )); then
            high_threshold=$DEFAULT_HIGH_THRESHOLD
            medium_threshold=$DEFAULT_MEDIUM_THRESHOLD
        fi
    fi

    sleep 1
done
