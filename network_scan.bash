#!/bin/bash

# Check all devices connected to the local network
# Extracts the main info (OS, ports, protocols, hostname) if available
# build a csv file containing a row for each device
# optionally uploads into Dropbox the report (/tmp/final_report_YYYYMMDD_HHMISS.csv)
# optionally checks if there is a difference with the last report available in Dropbox
# in case of differences (a new device appears or disappears) a notification into the log file is tracked

# ==============================
# Main configuration
# ==============================
NETWORK="192.168.1.0/24"
TMP_DIR="/tmp"

ENABLE_DROPBOX=1   # 1 = upload to Dropbox enabled, 0 = disabled
DROPBOX_DIR=""     # set your dropbox local dir if upload is enabled

ENABLE_COMPARE=1   # 1 = compare with last CSV, 0 = skip

# ==============================
# Validate Dropbox configuration
# ==============================
if [ "$ENABLE_DROPBOX" -eq 1 ]; then
    if [ -z "$DROPBOX_DIR" ]; then
        echo "ERROR: DROPBOX_DIR variable is not defined. Please set DROPBOX_DIR when ENABLE_DROPBOX=1."
        exit 1
    fi
fi

# ==============================
# Define working directory and log directory
# ==============================
WORK_DIR=$(pwd)                     
LOG_DIR="$WORK_DIR/LOG"            
mkdir -p "$LOG_DIR"

# Create Dropbox directory only if enabled
if [ "$ENABLE_DROPBOX" -eq 1 ]; then
    mkdir -p "$DROPBOX_DIR"
fi

# ==============================
# Timestamps for CSV and log
# ==============================
DATE=$(date +%Y%m%d_%H%M%S)
CSV_FILE="$TMP_DIR/final_report_$DATE.csv"
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="$LOG_DIR/${SCRIPT_NAME}_$DATE.log"

# Redirect all output to log file and also to terminal
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Starting script: $SCRIPT_NAME ==="
echo "Log file: $LOG_FILE"
echo "=== Scanning network: $NETWORK ==="
echo

# ==============================
# 1/3: Detect active hosts
# ==============================
echo "[1/3] Detecting active hosts..."
nmap -sn $NETWORK -oG $TMP_DIR/hosts_raw.txt > /dev/null
grep "Up" $TMP_DIR/hosts_raw.txt | awk '{print $2,$3}' | sed 's/[()]//g' > $TMP_DIR/hosts_list.txt
NUM_HOSTS=$(wc -l < $TMP_DIR/hosts_list.txt)
echo "Found $NUM_HOSTS active hosts."
echo

# ==============================
# 2/3: Collect MAC, Vendor, Open Ports
# ==============================
echo "[2/3] Collecting MAC addresses, vendor info, and open ports..."
echo "IP,Hostname,MAC,Vendor,OpenPorts" > "$CSV_FILE"

while read ip hostname; do
    mac=$(arp -n $ip | awk '/ether/ {print $3}')
    if [ -n "$mac" ]; then
        prefix=$(echo $mac | awk -F: '{print toupper($1$2$3)}')
        vendor=$(grep -i "^$prefix" /usr/share/nmap/nmap-mac-prefixes | cut -d' ' -f2-)
        [ -z "$vendor" ] && vendor="Unknown"
    else
        vendor="N/A"
    fi
    ports=$(nmap -Pn -p- --min-rate=500 $ip 2>/dev/null \
        | grep "/tcp" \
        | awk '{print $1}' \
        | tr '\n' ' ' \
        | sed 's/ $//')
    [ -z "$ports" ] && ports="None"
    echo "$ip,$hostname,$mac,$vendor,\"$ports\"" >> "$CSV_FILE"
done < $TMP_DIR/hosts_list.txt

echo "Data collected."
echo

# ==============================
# 3/4: Optional Copy to Dropbox
# ==============================
if [ "$ENABLE_DROPBOX" -eq 1 ]; then
    echo "[3/4] Copying to Dropbox..."
    cp "$CSV_FILE" "$DROPBOX_DIR/"

    if [ $? -eq 0 ]; then
        echo "File successfully copied to Dropbox: $DROPBOX_DIR/$(basename "$CSV_FILE")"
    else
        echo "Error copying file to Dropbox"
    fi
else
    echo "[3/4] Dropbox upload disabled. Skipping file copy."
fi

# ==============================
# 4/4: Optional comparison
# ==============================
if [ "$ENABLE_COMPARE" -eq 1 ] && [ "$ENABLE_DROPBOX" -eq 1 ]; then
    echo
    echo "[4/4] Comparing with the latest previous CSV in Dropbox..."
    
    LAST_CSV=$(ls -t "$DROPBOX_DIR"/final_report_*.csv 2>/dev/null | grep -v "$(basename "$CSV_FILE")" | head -n1)
    
    if [ -n "$LAST_CSV" ]; then
        echo "Last CSV found: $LAST_CSV"
        
        DIFF_OUTPUT=$(diff "$LAST_CSV" "$CSV_FILE")
        DIFF_EXIT_CODE=$?
        
        if [ $DIFF_EXIT_CODE -eq 0 ]; then
            echo "No differences found between the files."
        else
            echo "Differences found:"
            echo "-------------------"
            echo "$DIFF_OUTPUT"
            echo "-------------------"
        fi
    else
        echo "No previous CSV found to compare."
    fi
else
    if [ "$ENABLE_COMPARE" -eq 1 ] && [ "$ENABLE_DROPBOX" -eq 0 ]; then
        echo "[4/4] Comparison skipped because Dropbox upload is disabled."
    fi
fi

# ==============================
# Finished
# ==============================
echo
echo "=== Report generated ==="
echo " - $CSV_FILE"
echo "Scan completed."
echo "Log saved in: $LOG_FILE"
