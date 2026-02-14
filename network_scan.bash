campolinux@xps-13:~/SCRIPT/SHELL$ cat network_scan.bash 
#!/bin/bash

set -euo pipefail

# =====================================================
# Network Scan & Reporting Script - Robust Version
# =====================================================
# - Scans local network
# - Generates CSV report
# - Optionally uploads to Dropbox
# - Optionally compares with previous report
# - Sends Slack notification via external script
# =====================================================

# ==============================
# Configuration
# ==============================
NETWORK="192.168.1.0/24"
TMP_DIR="/tmp"
TOOL_DIR=""

ENABLE_DROPBOX=1
DROPBOX_DIR=""

ENABLE_COMPARE=1

ENABLE_SLACK=1
SLACK_CHANNEL="network"
SLACK_SCRIPT="${TOOL_DIR}/curl_post_slack.bash"

# ==============================
# Validate configuration
# ==============================
if [ "$ENABLE_DROPBOX" -eq 1 ] && [ -z "${DROPBOX_DIR:-}" ]; then
    echo "ERROR: DROPBOX_DIR is not defined."
    exit 1
fi

if [ "$ENABLE_SLACK" -eq 1 ]; then
    if [ -z "${SLACK_CHANNEL:-}" ]; then
        echo "ERROR: SLACK_CHANNEL is not defined."
        exit 1
    fi
    if [ ! -x "$SLACK_SCRIPT" ]; then
        echo "ERROR: Slack script '$SLACK_SCRIPT' not found or not executable."
        exit 1
    fi
fi

command -v nmap >/dev/null 2>&1 || { echo "ERROR: nmap not installed."; exit 1; }

# ==============================
# Directories
# ==============================
WORK_DIR=$(pwd)
LOG_DIR="$WORK_DIR/LOG"
mkdir -p "$LOG_DIR"

if [ "$ENABLE_DROPBOX" -eq 1 ]; then
    mkdir -p "$DROPBOX_DIR"
fi

# ==============================
# Timestamps
# ==============================
DATE=$(date +%Y%m%d_%H%M%S)
CSV_FILE="$TMP_DIR/final_report_$DATE.csv"
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}_$DATE.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================="
echo "Starting script: $SCRIPT_NAME"
echo "Network: $NETWORK"
echo "Log file: $LOG_FILE"
echo "================================================="
echo

# ==============================
# 1/4 Detect active hosts
# ==============================
echo "[1/4] Detecting active hosts..."
nmap -sn "$NETWORK" -oG "$TMP_DIR/hosts_raw.txt" > /dev/null
grep "Up" "$TMP_DIR/hosts_raw.txt" | awk '{print $2,$3}' | sed 's/[()]//g' > "$TMP_DIR/hosts_list.txt"
NUM_HOSTS=$(wc -l < "$TMP_DIR/hosts_list.txt")
echo "Found $NUM_HOSTS active hosts."
echo

# ==============================
# 2/4 Collect device info
# ==============================
echo "[2/4] Collecting device information..."
echo "IP,Hostname,MAC,Vendor,OpenPorts" > "$CSV_FILE"

while read -r ip hostname; do
    echo "Scanning $ip ($hostname)..."

    # --- MAC address ---
    mac=$(arp -n "$ip" 2>/dev/null | awk '/ether/ {print $3}' || true)
    vendor="N/A"

    if [ -n "$mac" ]; then
        prefix=$(echo "$mac" | awk -F: '{print toupper($1$2$3)}')
        vendor=$(grep -i "^$prefix" /usr/share/nmap/nmap-mac-prefixes 2>/dev/null | cut -d' ' -f2- || true)
        [ -z "$vendor" ] && vendor="Unknown"
    fi

    # --- Open ports ---
    ports=$(nmap -Pn --top-ports 1000 "$ip" 2>/dev/null \
        | grep "/tcp" \
        | awk '{print $1}' \
        | tr '\n' ' ' \
        | sed 's/ $//' || true)
    [ -z "$ports" ] && ports="None"

    # --- Write CSV ---
    echo "$ip,$hostname,$mac,$vendor,\"$ports\"" >> "$CSV_FILE"
done < "$TMP_DIR/hosts_list.txt"

echo "Data collection completed for $NUM_HOSTS hosts."
echo

# ==============================
# 3/4 Dropbox upload (optional)
# ==============================
if [ "$ENABLE_DROPBOX" -eq 1 ]; then
    echo "[3/4] Uploading to Dropbox..."
    cp "$CSV_FILE" "$DROPBOX_DIR/"
    echo "File copied to Dropbox."
else
    echo "[3/4] Dropbox upload disabled."
fi
echo

# ==============================
# 4/4 Compare (optional)
# ==============================
EMOJI="ℹ️"
STATUS_MESSAGE="Comparison skipped."

if [ "$ENABLE_COMPARE" -eq 1 ] && [ "$ENABLE_DROPBOX" -eq 1 ]; then
    echo "[4/4] Comparing with latest previous CSV..."

    LAST_CSV=$(ls -t "$DROPBOX_DIR"/final_report_*.csv 2>/dev/null | grep -v "$(basename "$CSV_FILE")" | head -n1)

    if [ -n "$LAST_CSV" ]; then
        if diff -q "$LAST_CSV" "$CSV_FILE" >/dev/null; then
            EMOJI="✅"
            STATUS_MESSAGE="($HOSTNAME) Network unchanged. No new or missing devices detected."
            echo "No differences found."
        else
            EMOJI="⚠️"
            STATUS_MESSAGE="($HOSTNAME) Network changes detected. Devices added or removed."
            echo "Differences detected."
        fi
    else
        EMOJI="⚠️"
        STATUS_MESSAGE="($HOSTNAME) First scan executed. No previous reference available."
        echo "No previous CSV found."
    fi
fi

echo

# ==============================
# Slack notification (external script)
# ==============================
if [ "$ENABLE_SLACK" -eq 1 ]; then
    echo "Sending Slack notification..."

    MESSAGE="$EMOJI Network Scan Report
Hosts detected: $NUM_HOSTS
Status: $STATUS_MESSAGE"

    "$SLACK_SCRIPT" "$MESSAGE" "$SLACK_CHANNEL"

    echo "Slack notification sent to #$SLACK_CHANNEL"
else
    echo "Slack notifications disabled."
fi

echo
echo "================================================="
echo "Report generated: $CSV_FILE"
echo "Scan completed successfully."
echo "Log saved in: $LOG_FILE"
echo "================================================="
