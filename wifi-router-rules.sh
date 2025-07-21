#!/bin/bash

# This script configures iptables to securely route all Wi-Fi client traffic
# through the VPN connection, implementing a kill switch to prevent leaks.

# --- Network Interface Variables ---
# WAN Interface (Internet connection)
WAN_IF="enp3s0"

# Wi-Fi Hotspot Interface
WIFI_IF="wlp3s0"
WIFI_SUBNET="192.168.100.0/24"

# VPN Virtual Interface
VPN_IF="tun0"


# --- 1. Enable IP Forwarding ---
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1


# --- 2. Flush Existing Rules and Chains ---
echo "Flushing existing iptables rules..."
iptables -F
iptables -t nat -F
iptables -X


# --- 3. Set Default Policies (Kill Switch Core) ---
# Block all forwarding by default. This is the kill switch.
# Traffic is only allowed if a specific rule permits it.
echo "Setting default FORWARD policy to DROP (Kill Switch)..."
iptables -P FORWARD DROP

# Allow all outgoing traffic from the router itself.
# This is crucial for the router to connect to the VPN and check its IP.
echo "Setting default OUTPUT policy to ACCEPT for the router itself..."
iptables -P OUTPUT ACCEPT

# Accept all incoming traffic to the router itself.
# More restrictive rules could be applied here, but ACCEPT is fine for this use case.
iptables -P INPUT ACCEPT


# --- 4. NAT (Network Address Translation) Rules ---
# Translate the source IP of packets from the Wi-Fi subnet to the VPN interface's IP.
# This makes the Wi-Fi clients appear to be coming from the VPN.
echo "Setting up NAT rule for Wi-Fi clients via VPN..."
iptables -t nat -A POSTROUTING -s $WIFI_SUBNET -o $VPN_IF -j MASQUERADE


# --- 5. Forwarding Rules ---
echo "Setting up forwarding rules..."

# Allow new connections from Wi-Fi clients to the VPN interface.
iptables -A FORWARD -i $WIFI_IF -o $VPN_IF -j ACCEPT

# Allow returning traffic from the VPN back to the Wi-Fi clients.
# This is essential for two-way communication (e.g., web page loading).
iptables -A FORWARD -i $VPN_IF -o $WIFI_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Allow returning traffic from the WAN back to the router itself (for established connections).
# This helps ensure the router's own connections (like the VPN tunnel) are stable.
iptables -A INPUT -i $WAN_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT


echo "Secure VPN router rules with kill switch applied successfully."
echo "All Wi-Fi traffic will be routed through $VPN_IF."
echo "If $VPN_IF is down, Wi-Fi traffic will be blocked."
