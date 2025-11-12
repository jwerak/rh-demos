#!/bin/bash
# Build and test the container image demonstration

set -e

# Check if main.tar.gz exists, if not create it
if [ ! -f "main.tar.gz" ]; then
    echo "========================================="
    echo "Archive not found - Creating main.tar.gz"
    echo "========================================="
    echo ""
    ./create-archive.sh
    echo ""
fi

echo "========================================="
echo "Building Container Image"
echo "========================================="
echo ""

# Build the container image
podman build -t demo-file-copy:latest -f Containerfile .

echo ""
echo "========================================="
echo "Build Complete!"
echo "========================================="
echo ""
echo "Image details:"
podman images demo-file-copy:latest

echo ""
echo "========================================="
echo "Running Container to Verify Files"
echo "========================================="
echo ""

# Run the container (will execute the verification script by default)
podman run --rm demo-file-copy:latest

echo ""
echo "========================================="
echo "Testing Application Script"
echo "========================================="
echo ""

# Run the app script
podman run --rm demo-file-copy:latest /opt/myapp/bin/app.sh

echo ""
echo "========================================="
echo "Interactive Mode Available"
echo "========================================="
echo ""
echo "To explore the container interactively, run:"
echo "  podman run --rm -it demo-file-copy:latest /bin/bash"
echo ""
echo "Then you can:"
echo "  - Run: verify-files.sh"
echo "  - Run: /opt/myapp/bin/app.sh"
echo "  - Explore: ls -la /etc/myapp/ /etc/custom/ /opt/myapp/"
echo "  - Verify: cat /etc/passwd  # Original file still exists"
echo "  - Check: cat /etc/myapp/service.conf  # New file added"
echo ""
