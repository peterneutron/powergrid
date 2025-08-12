#!/bin/bash
# uninstall.sh
#
# Uninstalls the PowerGrid daemon from macOS.
#
# This script will:
# 1. Stop and unload the launchd service.
# 2. Delete the daemon binary from /usr/local/bin.
# 3. Delete the launchd .plist file.
# 4. Delete the log files.

# Stop the script if any command fails
set -e

# --- Configuration (should match install.sh) ---
DAEMON_NAME="powergrid-daemon"
PLIST_NAME="com.neutronstar.powergrid.daemon.plist"

# --- System Paths ---
INSTALL_DIR="/usr/local/bin"
LAUNCHDAEMONS_DIR="/Library/LaunchDaemons"
DAEMON_INSTALL_PATH="${INSTALL_DIR}/${DAEMON_NAME}"
PLIST_INSTALL_PATH="${LAUNCHDAEMONS_DIR}/${PLIST_NAME}"
LOG_PATH="/var/log/powergrid.log"
ERROR_LOG_PATH="/var/log/powergrid.error.log"

echo "--- Uninstalling PowerGrid Daemon ---"

# 1. Stop and unload the service
if [ -f "${PLIST_INSTALL_PATH}" ]; then
    echo "Stopping and unloading the service..."
    sudo launchctl unload "${PLIST_INSTALL_PATH}" || true
else
    echo "Service .plist not found, skipping unload."
fi

# 2. Delete the launchd plist
if [ -f "${PLIST_INSTALL_PATH}" ]; then
    echo "Deleting launchd plist..."
    sudo rm "${PLIST_INSTALL_PATH}"
fi

# 3. Delete the daemon binary
if [ -f "${DAEMON_INSTALL_PATH}" ]; then
    echo "Deleting daemon binary..."
    sudo rm "${DAEMON_INSTALL_PATH}"
fi

# 4. Delete log files
if [ -f "${LOG_PATH}" ]; then
    echo "Deleting log file..."
    sudo rm "${LOG_PATH}"
fi
if [ -f "${ERROR_LOG_PATH}" ]; then
    echo "Deleting error log file..."
    sudo rm "${ERROR_LOG_PATH}"
fi

echo ""
echo "✅ PowerGrid Daemon has been successfully uninstalled."