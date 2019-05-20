#!/bin/bash

# Check for a pre-existing connection through wpa_supplicant.
# $1 = device interface
function check_conn {
    # First check to see if NetworkManager has any established connections. If
    # so, exit. It is best for the user to disconnect through NetworkManager
    # first.
    if grep -q "$1" <<< $(nmcli -c no c show); then
        echo "NetworkManager is currently running."
        exit 0
    fi
    # Check if there are any wpa_supplicant processes running.
    if grep -q wpa_supplicant <<< $(ps -e); then
        printf "\nwpa_supplicant is currently running.\n\n"
        while true; do
            read -p "Terminate all wpa_supplicant processes? " q
            if [[ $q =~ [yY] ]]; then
                # Try to terminate cleanly through wpa_cli.
                if ! wpa_cli terminate > /dev/null 2>&1; then
                    # Otherwise kill.
                    killall wpa_supplicant
                fi
                # If the program doesn't pause for a couple of seconds after
                # terminating wpa_supplicant, the access point scan won't work
                # on the first try.
                sleep 2
                break
            elif [[ $q =~ [nN] ]]; then
                exit 0
            else
                printf "\nInvalid input!\n"
            fi
        done
    fi
}

# Try connecting to the access point using the wpa_supplicant tool.
# $1 = device interface
# $2 = WPA-PSK data
function wpa_connect {
    # Run wpa_supplicant in the background (-B), with the wext driver (-D), for
    # the chosen device. Set the control interface to /run/wpa_supplicant so
    # that we can cleanly shut down wpa_supplicant through wpa_cli if this
    # script gets run again while still connected. Finally, pass the PSK data
    # variable as a process substitution. This is to make wpa_supplicant
    # connect to exactly the access point chosen. If we passed the whole config
    # file, it would have its own way of choosing from among the access points.
    # Exit if connection fails.
    if ! wpa_supplicant -B -D wext -i "$1" -C /run/wpa_supplicant -c <(cat <<< "$2") > /dev/null; then
        printf "\n\nConnection failed.\n\n"
        exit 0
    # If connection is successful, return success from the function.
    else
        return 0
    fi
}

# Get a PSK for the device.
# $1 = device interface
# $2 = access point SSID
function wpa_get {
    # If wpa_supplicant.conf does not exist or if the chosen
    # access point does not have an entry in it:
    if [ ! -f wpa_supplicant.conf ] ||
        ! grep -q 'ssid=\"'"$2"'\"' wpa_supplicant.conf; then
        # Get a password, give it to the wpa_passphrase tool
        # to get the PSK, and store the output in a variable.
        read -s -p "Password: " p
        wpa=$(wpa_passphrase "$2" "$p")
        # Try connecting to the access point with the PSK.
        # If it's a success, then append the PSK data to
        # wpa_supplicant.conf
        if wpa_connect "$1" "$wpa"; then
            cat <<< $wpa >> wpa_supplicant.conf
        fi
    # If there is already an entry for the access point, connect with it.
    else
        wpa=$(sed -rz 's/.*(network.*\"'"$2"'\"[^\}]*\}).*/\1/' wpa_supplicant.conf)
        wpa_connect "$1" "$wpa"
    fi
}

# Associate an IP with the device through dhclient.
# $1 = device interface
function ip_get {
    printf "\nGetting IP address from dhclient...\n"
    if dhclient $1; then
        printf "\nConnected.\n\n"
    else
        printf "\nConnection failed.\n\n"
    fi
}

# Print a menu of Wi-Fi access points and store selection.
function wifi_select {
    printf "\nScanning for access points...\n\n"
    readarray -t ssid <<< $(iw wlp6s0 scan | sed -rn 's/\s*SSID: //p')
    for ((i = 0; i < ${#ssid[@]}; i++))
    do
        echo -e '\t['"$i"']\t'"${ssid[$i]}"
    done
    printf "\n"
    read -p "Select network: " s
    if [[ $s == "" ]]; then
        wifi_select
    fi
}

# Read a list of wireless devices into the iface variable.
readarray -t iface <<< $(iw dev | sed -rn 's/\s*Interface ([a-z0-9]+)/\1/p')

# If there is more than one device:
if [ "${#iface[@]}" -gt 1 ]; then
    # Present a numbered selection menu.
    for ((i = 0; i < ${#iface[@]}; i++))
    do
        echo -e '\t['"$i"']\t'"${iface[$i]}"
    done
    read -p "Select device: " d
    iface=${iface[$d]}
else
    iface=${iface[0]}
fi

# Check for existing wpa_supplicant connections.
check_conn "$iface"

# Make sure the device is UP.
ip link set "$iface" up

# Remove any IP address that might be associated with the device.
ip address flush dev "$iface"

# If dhclient is already running, kill it.
if grep -q dhclient <<< $(ps -e); then
    killall dhclient
fi

# Access point selection menu.
wifi_select

# Get PSK for access point, either from user or config file.
wpa_get "$iface" "${ssid[$s]}"

# Request an IP address from dhclient.
ip_get "$iface"
