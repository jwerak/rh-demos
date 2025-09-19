#!/bin/bash

# Cleanup script for IP alias lab setup
# This script removes VMs, networks, and bridge connections created during setup

set -e

DOMAIN_NAME_BASE=00-lab
IMAGE_BASE_PATH=/var/lib/libvirt/images
BRIDGE_NAME=bridge0
NETWORK_NAME=network-internal

echo "=== Starting cleanup of IP alias lab setup ==="

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if running as root/sudo for certain operations
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script needs to be run with sudo for some operations."
        echo "Usage: sudo $0"
        exit 1
    fi
}

# Remove VMs and their disk images
echo "--- Removing VMs and disk images ---"
for i in {01..02}; do
    DOMAIN_NAME=${DOMAIN_NAME_BASE}-${i}
    IMAGE_PATH=${IMAGE_BASE_PATH}/${DOMAIN_NAME}.qcow2

    echo "Processing VM: ${DOMAIN_NAME}"

    # Check if VM exists and is running
    if virsh list --all | grep -q "${DOMAIN_NAME}"; then
        # Force shutdown if running
        if virsh list --state-running | grep -q "${DOMAIN_NAME}"; then
            echo "  Shutting down ${DOMAIN_NAME}..."
            virsh destroy "${DOMAIN_NAME}" 2>/dev/null || true
        fi

        # Undefine the VM
        echo "  Removing VM definition for ${DOMAIN_NAME}..."
        virsh undefine "${DOMAIN_NAME}" --remove-all-storage 2>/dev/null || true
    else
        echo "  VM ${DOMAIN_NAME} not found, skipping..."
    fi

    # Remove disk image if it exists
    if [ -f "${IMAGE_PATH}" ]; then
        echo "  Removing disk image: ${IMAGE_PATH}"
        rm -f "${IMAGE_PATH}"
    else
        echo "  Disk image ${IMAGE_PATH} not found, skipping..."
    fi
done

# Remove libvirt network
echo "--- Removing libvirt network ---"
if virsh net-list --all | grep -q "${NETWORK_NAME}"; then
    # Stop the network if it's active
    if virsh net-list | grep -q "${NETWORK_NAME}"; then
        echo "  Stopping network ${NETWORK_NAME}..."
        virsh net-destroy "${NETWORK_NAME}" 2>/dev/null || true
    fi

    # Remove autostart
    echo "  Disabling autostart for ${NETWORK_NAME}..."
    virsh net-autostart "${NETWORK_NAME}" --disable 2>/dev/null || true

    # Undefine the network
    echo "  Removing network definition for ${NETWORK_NAME}..."
    virsh net-undefine "${NETWORK_NAME}" 2>/dev/null || true
else
    echo "  Network ${NETWORK_NAME} not found, skipping..."
fi

# Remove bridge connection (optional - uncomment if you want to remove it)
echo "--- Bridge connection cleanup ---"
if command_exists nmcli; then
    if nmcli connection show | grep -q "${BRIDGE_NAME}"; then
        echo "  Bridge connection ${BRIDGE_NAME} found."
        echo "  To remove the bridge connection, run:"
        echo "    sudo nmcli connection down ${BRIDGE_NAME}"
        echo "    sudo nmcli connection delete ${BRIDGE_NAME}"
        echo "    sudo nmcli connection delete bridge-slave-*"
        echo "  Note: This might affect your network connectivity. Remove manually if needed."
    else
        echo "  Bridge connection ${BRIDGE_NAME} not found, skipping..."
    fi
else
    echo "  nmcli not found, skipping bridge cleanup..."
fi

echo ""
echo "=== Cleanup completed! ==="
echo ""
echo "Summary of actions performed:"
echo "- Removed VMs: ${DOMAIN_NAME_BASE}-01, ${DOMAIN_NAME_BASE}-02"
echo "- Removed VM disk images from ${IMAGE_BASE_PATH}/"
echo "- Removed libvirt network: ${NETWORK_NAME}"
echo "- Bridge connection ${BRIDGE_NAME} cleanup instructions provided"
echo ""
echo "To verify cleanup:"
echo "  virsh list --all"
echo "  virsh net-list --all"
echo "  nmcli connection show"
