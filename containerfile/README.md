# Containerfile Demo: Copying Files from Localhost to Container Image

This demonstration shows how to copy multiple files from localhost to a container image while:
- Preserving directory structure using tar archives
- Merging new files with existing container filesystem
- Keeping original system files intact (e.g., files in `/etc`)
- Adding new custom files and directories
- Using ADD directive for automatic archive extraction

## Overview

This demo creates a single tar archive from sample directories (`/opt` and `/etc` structure) on the localhost, using a manifest file to define which files to include. The archive is then copied into a container image using the ADD directive, which automatically extracts it. The key point is that the extraction **merges** with the existing container filesystem rather than replacing it.

## Directory Structure

```
containerfile/
├── Containerfile              # Container build instructions
├── archive-manifest.txt       # Defines which files to include in archive
├── create-archive.sh          # Script to create main.tar.gz from manifest
├── build-and-test.sh          # Script to build and test the image
├── main.tar.gz                # Combined archive (created by create-archive.sh)
├── sample_files/              # Source files (before archiving)
│   ├── opt/
│   │   └── myapp/
│   │       ├── bin/
│   │       │   └── app.sh
│   │       └── config/
│   │           └── app.conf
│   └── etc/
│       ├── myapp/
│       │   └── service.conf
│       └── custom/
│           └── custom.conf
└── README.md                  # This file (documentation)
```

## How It Works

### 1. Create Sample Directories and Files

The `sample_files/` directory contains:
- **opt/myapp/** - Application binaries and configuration
- **etc/myapp/** - Service configuration files
- **etc/custom/** - Custom configuration files

### 2. Define Files to Archive

The `archive-manifest.txt` file lists all files and directories to include:

```
opt/myapp/bin/app.sh
opt/myapp/config/app.conf
etc/myapp/service.conf
etc/custom/custom.conf
```

### 3. Create Single Tar Archive

Run the `create-archive.sh` script to create `main.tar.gz`:

```bash
./create-archive.sh
```

This script:
- Reads the manifest file
- Filters out comments and empty lines
- Creates a single tar archive with all specified files
- Preserves the directory structure (relative paths like `opt/myapp/bin/app.sh`)

### 4. Containerfile Process

The Containerfile:
1. Starts with UBI 9 base image (which already has `/etc` with system files)
2. Uses ADD directive with `main.tar.gz`
3. ADD automatically decompresses and extracts the archive to root (`/`)
4. Files merge with existing filesystem
5. Verifies that:
   - Original `/etc` files (passwd, group, hosts, etc.) still exist
   - New custom files are added to `/etc/myapp/` and `/etc/custom/`
   - New application files are created in `/opt/myapp/`

### 5. Key Concept: ADD Directive

The ADD directive has special behavior with tar archives:

```dockerfile
ADD main.tar.gz /
```

When ADD detects a compressed tar archive, it automatically:
- Decompresses the archive
- Extracts contents to the destination directory
- Merges with existing filesystem (preserves original files)
- Does NOT keep the archive file in the image

### 6. Merging vs. Replacing

When extracting archives to `/`:
- **Existing files are preserved** (unless the tar contains files with identical paths)
- **New directories and files are added** alongside existing ones
- The original `/etc/passwd`, `/etc/group`, etc. remain untouched
- New subdirectories like `/etc/myapp/` are created

## Usage

### Quick Start

#### 1. Create the Archive

First, create the main.tar.gz archive from the manifest:

```bash
./create-archive.sh
```

#### 2. Build and Test

Run the automated build and test script:

```bash
./build-and-test.sh
```

This will:
1. Build the container image with podman
2. Run the container and display verification report
3. Test the application script
4. Show instructions for interactive exploration

### Manual Steps

#### 1. Create the Archive

```bash
./create-archive.sh
```

#### 2. Build the Image

```bash
podman build -t demo-file-copy:latest -f Containerfile .
```

#### 3. Run Verification

```bash
podman run --rm demo-file-copy:latest
```

This executes the built-in verification script that checks:
- Original system files in `/etc` still exist
- New custom files were added to `/etc`
- Application files were created in `/opt`

#### 4. Interactive Exploration

```bash
podman run --rm -it demo-file-copy:latest /bin/bash
```

Inside the container, try:

```bash
# Run the verification script
verify-files.sh

# Check original /etc files still exist
ls -la /etc/passwd /etc/group /etc/hosts

# Check new custom files were added
cat /etc/myapp/service.conf
cat /etc/custom/custom.conf

# Check /opt application files
cat /opt/myapp/config/app.conf
/opt/myapp/bin/app.sh

# View directory structure
find /opt -type f -o -type d
find /etc/myapp /etc/custom -type f -o -type d

# Count total files in /etc
find /etc -type f | wc -l
```

## Key Takeaways

1. **Manifest-Driven Approach**: Use a manifest file (`archive-manifest.txt`) to define exactly which files to include, making it easy to maintain and modify.

2. **Single Archive**: Combine all files into one `main.tar.gz` archive for cleaner management.

3. **ADD Directive**: ADD automatically extracts tar archives, simplifying the Containerfile.

4. **Tar Archives Preserve Structure**: Using tar with relative paths preserves the exact directory structure you want in the container.

5. **Extraction Merges Files**: Extracting to `/` adds new files and directories without removing existing ones.

6. **System Files Remain**: Original system files like `/etc/passwd`, `/etc/group`, `/etc/hostname` are preserved.

7. **Custom Files Added**: New configuration directories and files are added alongside system files.

8. **Practical Use Cases**:
   - Adding application configurations to `/etc`
   - Installing custom applications to `/opt`
   - Deploying multiple configuration files while maintaining system integrity
   - Migrating configuration from one system to another

## Recreating the Sample Files

If you need to recreate the sample files and archives:

```bash
# Create directory structure
mkdir -p sample_files/opt/myapp/{bin,config}
mkdir -p sample_files/etc/{myapp,custom}

# Create opt files
cat > sample_files/opt/myapp/bin/app.sh << 'EOF'
#!/bin/bash
echo "Running MyApp from /opt/myapp/bin"
EOF

cat > sample_files/opt/myapp/config/app.conf << 'EOF'
# MyApp Configuration
APP_NAME=myapp
APP_VERSION=1.0.0
LOG_LEVEL=info
DATA_DIR=/var/lib/myapp
EOF

# Create etc files
cat > sample_files/etc/myapp/service.conf << 'EOF'
# Service Configuration
SERVICE_PORT=8080
SERVICE_HOST=0.0.0.0
MAX_CONNECTIONS=100
TIMEOUT=30
EOF

cat > sample_files/etc/custom/custom.conf << 'EOF'
# Custom Configuration
CUSTOM_SETTING_1=value1
CUSTOM_SETTING_2=value2
FEATURE_FLAG_X=enabled
EOF

# Create the archive from manifest
./create-archive.sh
```

## Cleanup

To remove the built image:

```bash
podman rmi demo-file-copy:latest
```

To remove all sample files and start fresh:

```bash
rm -rf sample_files/ main.tar.gz
```

## Modifying the Archive Contents

To add or remove files from the archive:

1. **Edit the manifest**: Modify `archive-manifest.txt` to add/remove file paths
2. **Recreate the archive**: Run `./create-archive.sh`
3. **Rebuild the image**: Run `./build-and-test.sh` or `podman build ...`

Example: Adding a new file to the manifest:

```bash
# Add the new file entry to archive-manifest.txt
echo "opt/myapp/bin/new-script.sh" >> archive-manifest.txt

# Create the actual file in sample_files/
cat > sample_files/opt/myapp/bin/new-script.sh << 'EOF'
#!/bin/bash
echo "New script!"
EOF

# Recreate the archive
./create-archive.sh

# Rebuild the image
podman build -t demo-file-copy:latest -f Containerfile .
```

## Additional Resources

- [Podman Documentation](https://docs.podman.io/)
- [Containerfile/Dockerfile Reference](https://docs.docker.com/engine/reference/builder/)
- [ADD Directive Documentation](https://docs.docker.com/engine/reference/builder/#add)
- [tar Command Manual](https://www.gnu.org/software/tar/manual/)