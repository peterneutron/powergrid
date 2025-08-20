#!/bin/bash

set -e

DAEMON_SOURCE_DIR="./cmd/powergrid-daemon"
DAEMON_NAME="powergrid-daemon"
BUILD_DIR="./build"
PLIST_NAME="com.neutronstar.powergrid.daemon.plist"
PLIST_SOURCE_PATH="./install/${PLIST_NAME}"
INSTALL_DIR="/usr/local/bin"
LAUNCHDAEMONS_DIR="/Library/LaunchDaemons"
DAEMON_INSTALL_PATH="${INSTALL_DIR}/${DAEMON_NAME}"
PLIST_INSTALL_PATH="${LAUNCHDAEMONS_DIR}/${PLIST_NAME}"

echo "--- Building PowerGrid Daemon ---"
mkdir -p "${BUILD_DIR}"
CGO_ENABLED=1 go build -o "${BUILD_DIR}/${DAEMON_NAME}" "${DAEMON_SOURCE_DIR}"
echo "✅ Daemon built successfully."

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

if [ -f "${PLIST_INSTALL_PATH}" ]; then
    echo "Unloading existing service..."
    sudo launchctl unload "${PLIST_INSTALL_PATH}" || true
fi

echo "Copying daemon to ${INSTALL_DIR}..."
sudo cp "${BUILD_DIR}/${DAEMON_NAME}" "${DAEMON_INSTALL_PATH}"
sudo chown root:wheel "${DAEMON_INSTALL_PATH}"
sudo chmod 755 "${DAEMON_INSTALL_PATH}"

echo "Copying launchd plist to ${LAUNCHDAEMONS_DIR}..."
sudo cp "${PLIST_SOURCE_PATH}" "${PLIST_INSTALL_PATH}"
sudo chown root:wheel "${PLIST_INSTALL_PATH}"
sudo chmod 644 "${PLIST_INSTALL_PATH}"

echo "Loading new service..."
sudo launchctl load "${PLIST_INSTALL_PATH}"

echo ""
echo "✅ PowerGrid Daemon installed and started!"
echo "You can check its status with: sudo launchctl list | grep powergrid"
echo "And view logs at: /var/log/powergrid.log"