#!/usr/bin/env bash

# This script must be run with root privileges.

# --- Configuration ---
VPNGATE_URL="https://www.vpngate.net/api/iphone/"
OPENVPN_OPTIONS="--config /dev/stdin --log /dev/null"

# Hotspot Configuration
WIFI_DEV="wlp3s0"
SSID="aaa"
PASSWORD="ddd"

# --- State ---
VPN_PID=0
# Statically defined hotspot connection name
HOTSPOT_CONNECTION_NAME="hotspot"

# --- Functions ---

function global_ip {
  curl -s --max-time 10 inet-ip.info
}

function cleanup {
  echo "Caught signal, shutting down..."
  
  # Stop and delete the hotspot
  echo "Deactivating and deleting Wi-Fi hotspot ($HOTSPOT_CONNECTION_NAME)..."
  sudo nmcli connection down "$HOTSPOT_CONNECTION_NAME" >/dev/null 2>&1
  sudo nmcli connection delete "$HOTSPOT_CONNECTION_NAME" >/dev/null 2>&1
  
  if [ $VPN_PID -ne 0 ] && ps -p $VPN_PID > /dev/null; then
    echo "Stopping OpenVPN process (PID: $VPN_PID)..."
    sudo kill $VPN_PID
    sleep 2
  fi
  
  sudo pkill openvpn
  echo "VPN connections terminated."
  exit 0
}

# --- Main Execution ---

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use 'sudo'." >&2
  exit 1
fi

trap cleanup EXIT SIGINT SIGTERM

# Clean up any previous hotspot connection profile to ensure a clean start
echo "Deleting any existing hotspot connection profile..."
sudo nmcli connection delete "$HOTSPOT_CONNECTION_NAME" >/dev/null 2>&1
sleep 1

# Create and activate a hotspot using a more reliable method
echo "Creating and activating Wi-Fi hotspot..."
sudo nmcli connection add type wifi ifname "$WIFI_DEV" con-name "$HOTSPOT_CONNECTION_NAME" ssid "$SSID" mode ap ipv4.method shared 802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.psk "$PASSWORD"
if [ $? -ne 0 ]; then
    echo "Failed to create hotspot connection profile."
    exit 1
fi

sudo nmcli connection up "$HOTSPOT_CONNECTION_NAME"
if [ $? -ne 0 ]; then
    echo "Failed to activate hotspot. Please check your Wi-Fi device."
    # Clean up the created profile before exiting
    sudo nmcli connection delete "$HOTSPOT_CONNECTION_NAME" >/dev/null 2>&1
    exit 1
fi

echo "Hotspot '$HOTSPOT_CONNECTION_NAME' created successfully."
sleep 2

# Clean up any previous openvpn processes and apply firewall rules
sudo pkill openvpn
sleep 1
sudo bash wifi-router-rules.sh

# Store the IP address before connecting
BEFORE_IP=$(global_ip)
if [ -z "$BEFORE_IP" ]; then
  echo "Could not determine initial public IP. Please check your internet connection."
  exit 1
fi
echo "Your public IP before connecting is: $BEFORE_IP"

# Main loop to find and maintain a VPN connection
while :; do
  echo "Searching for a Japanese VPN server..."
  
  SERVER_LIST=$(curl -s "$VPNGATE_URL" | grep ',Japan,JP,' | grep -v 'public-vpn-' | sort -t',' -k5 -n -r | head -10 | sort -R)

  if [ -z "$SERVER_LIST" ]; then
    echo "Could not retrieve VPN server list. Retrying in 30 seconds..."
    sleep 30
    continue
  fi

  while read -r line; do
    OVPN_CONFIG=$(echo "$line" | cut -d',' -f15 | base64 -d)
    
    if [ -z "$OVPN_CONFIG" ]; then
      echo "Failed to decode a server configuration. Skipping."
      continue
    fi

    echo "Attempting to connect to a new server..."
    echo "$OVPN_CONFIG" | sudo openvpn $OPENVPN_OPTIONS &
    VPN_PID=$!

    echo "Waiting 15 seconds for connection to establish (PID: $VPN_PID)..."
    sleep 15

    AFTER_IP=$(global_ip)
    
    if [ $? -eq 0 ] && [ -n "$AFTER_IP" ] && [ "$BEFORE_IP" != "$AFTER_IP" ]; then
      echo "VPN connection successful! Current IP: $AFTER_IP"
      
      while :; do
        if ! ps -p $VPN_PID > /dev/null; then
          echo "VPN process (PID: $VPN_PID) is no longer running. Finding a new server..."
          VPN_PID=0
          break
        fi

        CURRENT_IP=$(global_ip)
        if [ $? -ne 0 ] || [ "$BEFORE_IP" = "$CURRENT_IP" ]; then
          echo "Health check failed. IP has reverted or is unreachable. Restarting connection..."
          sudo kill $VPN_PID
          VPN_PID=0
          break
        fi
        
        echo "Connection is stable. Current IP: $CURRENT_IP. Checking again in 60 seconds."
        sleep 60
      done

    else
      echo "Connection failed. IP address did not change or could not be fetched."
      echo "Killing failed OpenVPN process (PID: $VPN_PID)..."
      sudo kill $VPN_PID
      VPN_PID=0
      sleep 1
    fi
  done <<< "$SERVER_LIST"

  echo "Exhausted all servers in the list. Fetching a new list..."
  sleep 5
done
