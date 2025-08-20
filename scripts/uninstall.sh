#!/bin/bash

set -e

DAEMON_NAME="powergrid-daemon"
PLIST_NAME="com.neutronstar.powergrid.daemon.plist"
INSTALL_DIR="/usr/local/bin"
LAUNCHDAEMONS_DIR="/Library/LaunchDaemons"
DAEMON_INSTALL_PATH="${INSTALL_DIR}/${DAEMON_NAME}"
PLIST_INSTALL_PATH="${LAUNCHDAEMONS_DIR}/${PLIST_NAME}"
LOG_PATH="/var/log/powergrid.log"
ERROR_LOG_PATH="/var/log/powergrid.error.log"

echo "--- Uninstalling PowerGrid Daemon ---"

if [ -f "${PLIST_INSTALL_PATH}" ]; then
    echo "Stopping and unloading the service..."
    sudo launchctl unload "${PLIST_INSTALL_PATH}" || true
else
    echo "Service .plist not found, skipping unload."
fi

if [ -f "${PLIST_INSTALL_PATH}" ]; then
    echo "Deleting launchd plist..."
    sudo rm "${PLIST_INSTALL_PATH}"
fi

if [ -f "${DAEMON_INSTALL_PATH}" ]; then
    echo "Deleting daemon binary..."
    sudo rm "${DAEMON_INSTALL_PATH}"
fi

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