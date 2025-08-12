#!/bin/bash
# install.sh
#
# Builds and installs the PowerGrid daemon on macOS.
#
# This script will:
# 1. Build the Go binary.
# 2. Check if an old version is installed.
# 3. Prompt the user to upgrade if an old version is found.
# 4. Unload the old service, copy the new files, and load the new service.

# Stop the script if any command fails
set -e

# --- Configuration ---
DAEMON_SOURCE_DIR="./cmd/powergrid-daemon"
DAEMON_NAME="powergrid-daemon"
BUILD_DIR="./build"
PLIST_NAME="com.neutronstar.powergrid.daemon.plist"
PLIST_SOURCE_PATH="./install/${PLIST_NAME}"

# --- System Paths ---
INSTALL_DIR="/usr/local/bin"
LAUNCHDAEMONS_DIR="/Library/LaunchDaemons"
DAEMON_INSTALL_PATH="${INSTALL_DIR}/${DAEMON_NAME}"
PLIST_INSTALL_PATH="${LAUNCHDAEMONS_DIR}/${PLIST_NAME}"

echo "--- Building PowerGrid Daemon ---"
# Create build directory if it doesn't exist
mkdir -p "${BUILD_DIR}"
# Build the daemon statically, which is good practice for daemons.
CGO_ENABLED=1 go build -o "${BUILD_DIR}/${DAEMON_NAME}" "${DAEMON_SOURCE_DIR}"
echo "✅ Daemon built successfully."

# --- Check for Existing Installation ---
if [ -f "${DAEMON_INSTALL_PATH}" ]; then
    echo "ℹ️ An existing PowerGrid daemon was found."
    read -p "Would you like to upgrade it with the new build? [Y/n] " choice
    case "$choice" in
      n|N )
        echo "Aborting installation."
        exit 0
        ;;
      * )
        echo "Proceeding with upgrade..."
        ;;
    esac
fi

echo "--- Installing PowerGrid Daemon ---"

# 1. Unload any old version of the service to prevent conflicts
if [ -f "${PLIST_INSTALL_PATH}" ]; then
    echo "Unloading existing service..."
    sudo launchctl unload "${PLIST_INSTALL_PATH}" || true
fi

# 2. Install the new daemon binary
echo "Copying daemon to ${INSTALL_DIR}..."
sudo cp "${BUILD_DIR}/${DAEMON_NAME}" "${DAEMON_INSTALL_PATH}"
sudo chown root:wheel "${DAEMON_INSTALL_PATH}"
sudo chmod 755 "${DAEMON_INSTALL_PATH}"

# 3. Install the new launchd plist
echo "Copying launchd plist to ${LAUNCHDAEMONS_DIR}..."
sudo cp "${PLIST_SOURCE_PATH}" "${PLIST_INSTALL_PATH}"
sudo chown root:wheel "${PLIST_INSTALL_PATH}"
sudo chmod 644 "${PLIST_INSTALL_PATH}"

# 4. Load the new service
echo "Loading new service..."
sudo launchctl load "${PLIST_INSTALL_PATH}"

echo ""
echo "✅ PowerGrid Daemon installed and started!"
echo "You can check its status with: sudo launchctl list | grep powergrid"
echo "And view logs at: /var/log/powergrid.log"