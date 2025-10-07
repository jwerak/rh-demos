#!/bin/bash
# Script to create main.tar.gz from files listed in archive-manifest.txt

set -e

MANIFEST_FILE="archive-manifest.txt"
SOURCE_DIR="sample_files"
OUTPUT_ARCHIVE="main.tar.gz"

echo "========================================="
echo "Creating Archive from Manifest"
echo "========================================="
echo ""

# Check if manifest file exists
if [ ! -f "$MANIFEST_FILE" ]; then
    echo "ERROR: Manifest file '$MANIFEST_FILE' not found!"
    exit 1
fi

# Check if source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Source directory '$SOURCE_DIR' not found!"
    exit 1
fi

# Create a temporary file list (filtering out comments and empty lines)
TEMP_FILE_LIST=$(mktemp)
trap "rm -f $TEMP_FILE_LIST" EXIT

echo "Reading manifest file: $MANIFEST_FILE"
grep -v '^#' "$MANIFEST_FILE" | grep -v '^[[:space:]]*$' > "$TEMP_FILE_LIST"

echo "Files/directories to include:"
cat "$TEMP_FILE_LIST" | sed 's/^/  - /'
echo ""

# Change to source directory and create the archive
cd "$SOURCE_DIR"

echo "Creating archive: $OUTPUT_ARCHIVE"
# Read files from the temp list and create archive
# TEMP_FILE_LIST already contains absolute path from mktemp
tar -czf "../$OUTPUT_ARCHIVE" -T "$TEMP_FILE_LIST"

cd ..

# Verify the archive was created
if [ -f "$OUTPUT_ARCHIVE" ]; then
    echo ""
    echo "✅ Archive created successfully!"
    echo "   File: $OUTPUT_ARCHIVE"
    echo "   Size: $(ls -lh $OUTPUT_ARCHIVE | awk '{print $5}')"
    echo ""
    echo "Archive contents:"
    tar -tzf "$OUTPUT_ARCHIVE" | sed 's/^/  - /'
else
    echo "ERROR: Failed to create archive!"
    exit 1
fi

echo ""
echo "========================================="
echo "Archive Creation Complete"
echo "========================================="
