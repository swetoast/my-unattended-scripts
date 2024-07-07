#!/bin/bash

# Set your high and medium temperature thresholds in degrees Celsius
HIGH_THRESHOLD=60
MEDIUM_THRESHOLD=50

# Set your GPIO pin connected to the fan
GPIO_PIN=45

# Set the fan state to off initially
FAN_STATE="off"

# Set the spin time in seconds (3 minutes = 180 seconds)
SPIN_TIME=180

# Set the start and end of the quiet hours (22:00 - 08:00)
QUIET_HOURS_START=22
QUIET_HOURS_END=8

# Function to get the temperature
get_temp() {
    vcgencmd measure_temp | awk -F '[=.]' '{print $2}'
}

# Function to control the fan
control_fan() {
    local state=$1
    if [[ $state == "high" ]]; then
        pinctrl set $GPIO_PIN a1
    elif [[ $state == "medium" ]]; then
        pinctrl set $GPIO_PIN a2
    fi
    FAN_STATE=$state
    echo "Fan set to $state speed. Starting to poll GPIO pin state..."
    # Create a temporary file
    TEMP_FILE=$(mktemp)
    # Start polling in the background and store the data in the temporary file
    pinctrl poll $GPIO_PIN > $TEMP_FILE &
    POLL_PID=$!
    # Sleep for the spin time
    sleep $SPIN_TIME
}

# Function to stop polling
stop_polling() {
    # Kill the background polling process using its process ID
    kill $POLL_PID
    # Read and print the data from the temporary file
    local pin_state=$(cat $TEMP_FILE)
    echo "Stopped polling GPIO pin state. Data: $pin_state"
    # Remove the temporary file
    rm $TEMP_FILE
}

# Function to stop the fans
stop_fans() {
    pinctrl $GPIO_PIN a0
    FAN_STATE="off"
    echo "Fan turned off."
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

    # Determine the desired fan state based on the temperature
    if (( TEMP > HIGH_THRESHOLD )); then
        if [[ $FAN_STATE != "high" ]]; then
            control_fan "high"
        fi
    elif (( TEMP > MEDIUM_THRESHOLD )); then
        if [[ $FAN_STATE != "medium" ]]; then
            control_fan "medium"
        fi
    else
        if [[ $FAN_STATE != "off" ]]; then
            stop_polling
            stop_fans
        fi
    fi
    sleep 1
done
