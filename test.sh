#!/bin/bash

# Exit on any error
set -e

# Variables
WORK_DIR="/tmp/zfs-test"
KEY_FILE="$WORK_DIR/test.key"
POOL_NAME="test"
NUM_DISKS=5
DISK_SIZE="1G"

# Function to create the LUKS-encrypted ZFS RAIDZ2 pool
create_pool() {
    echo "=== Creating LUKS-encrypted ZFS RAIDZ2 test environment ==="

    # Create working directory
    echo "Creating working directory..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Create key file if it doesn't exist
    echo "Setting up LUKS key..."
    if [ ! -f "$KEY_FILE" ]; then
        echo "Generating random key file..."
        dd if=/dev/urandom of="$KEY_FILE" bs=512 count=1
        chmod 400 "$KEY_FILE"
    else
        echo "Using existing key file: $KEY_FILE"
    fi

    # Create sparse files for testing
    echo "Creating $NUM_DISKS sparse files of size $DISK_SIZE..."
    for i in $(seq 0 $((NUM_DISKS - 1))); do
        truncate -s $DISK_SIZE "$WORK_DIR/test${i}"
    done

    # Setup LUKS on files directly
    echo "Setting up LUKS encryption on disk files..."
    for i in $(seq 0 $((NUM_DISKS - 1))); do
        DISK_FILE="$WORK_DIR/test${i}"
        
        # Format with LUKS
        echo "Formatting $DISK_FILE with LUKS..."
        sudo cryptsetup luksFormat --type luks2 --key-file="$KEY_FILE" "$DISK_FILE" --batch-mode
        
        # Open LUKS device
        echo "Opening LUKS device as test${i}..."
        sudo cryptsetup luksOpen --key-file="$KEY_FILE" "$DISK_FILE" "test${i}"
    done

    # List the mapped devices
    echo "Mapped LUKS devices:"
    ls -la /dev/mapper/test*

    # Create RAIDZ2 pool
    echo "Creating RAIDZ2 pool named '$POOL_NAME'..."
    DEVICES=""
    for i in $(seq 0 $((NUM_DISKS - 1))); do
        DEVICES="$DEVICES /dev/mapper/test${i}"
    done

    sudo zpool create -f "$POOL_NAME" raidz2 $DEVICES

    # Show pool status
    echo "=== ZFS Pool Status ==="
    sudo zpool status "$POOL_NAME"

    echo ""
    echo "=== Setup Complete ==="
    echo "Pool name: $POOL_NAME"
    echo "Key file: $KEY_FILE"
    echo "Working directory: $WORK_DIR"
    echo "Disk images: $WORK_DIR/test{0..4}"
    echo "LUKS devices: /dev/mapper/test{0..4}"
    echo ""
}

# Function to unmount (export pool and close LUKS devices)
unmount_pool() {
    echo "=== Unmounting LUKS-encrypted ZFS RAIDZ2 environment ==="

    # Export ZFS pool
    if sudo zpool list "$POOL_NAME" &>/dev/null; then
        echo "Exporting ZFS pool '$POOL_NAME'..."
        sudo zpool export "$POOL_NAME"
        echo "Pool exported successfully"
    else
        echo "Pool '$POOL_NAME' not found or already exported"
    fi

    # Close LUKS devices
    echo "Closing LUKS devices..."
    for i in $(seq 0 $((NUM_DISKS - 1))); do
        if [ -e "/dev/mapper/test${i}" ]; then
            echo "Closing test${i}..."
            sudo cryptsetup luksClose "test${i}"
        fi
    done

    echo "Unmount complete"
}

# Function to mount (open LUKS devices and import pool)
mount_pool() {
    echo "=== Mounting LUKS-encrypted ZFS RAIDZ2 environment ==="

    # Check if working directory exists
    if [ ! -d "$WORK_DIR" ]; then
        echo "Error: Working directory $WORK_DIR not found"
        echo "Please run 'create' first"
        exit 1
    fi

    # Check if key file exists
    if [ ! -f "$KEY_FILE" ]; then
        echo "Error: Key file $KEY_FILE not found"
        exit 1
    fi

    # Open LUKS devices directly from files
    echo "Opening LUKS devices..."
    for i in $(seq 0 $((NUM_DISKS - 1))); do
        DISK_FILE="$WORK_DIR/test${i}"
        if [ -f "$DISK_FILE" ]; then
            # Open LUKS device if not already open
            if [ ! -e "/dev/mapper/test${i}" ]; then
                echo "Opening LUKS device as test${i}..."
                sudo cryptsetup luksOpen --key-file="$KEY_FILE" "$DISK_FILE" "test${i}"
            else
                echo "LUKS device test${i} already open"
            fi
        else
            echo "Warning: test${i} not found"
        fi
    done

    # Import ZFS pool
    echo "Importing ZFS pool '$POOL_NAME'..."
    if sudo zpool import "$POOL_NAME" 2>/dev/null; then
        echo "Pool imported successfully"
    else
        echo "Attempting to import with directory hint..."
        sudo zpool import -d /dev/mapper "$POOL_NAME"
    fi

    # Show pool status
    echo "=== ZFS Pool Status ==="
    sudo zpool status "$POOL_NAME"
}

# Function to destroy everything
destroy_pool() {
    echo "=== Destroying LUKS-encrypted ZFS RAIDZ2 test environment ==="

    # Stop NBD servers if running
    stop_nbd

    # First unmount everything
    unmount_pool

    # Remove working directory
    if [ -d "$WORK_DIR" ]; then
        echo "Removing working directory..."
        rm -rf "$WORK_DIR"
        echo "Removed $WORK_DIR"
    fi

    echo "Destroy complete - all test resources have been removed"
}

# Function to start NBD servers
start_nbd() {
    echo "=== Starting NBD server for test images ==="

    # Check if nbdkit is installed
    if ! command -v nbdkit &> /dev/null; then
        echo "Error: nbdkit is not installed"
        echo "Install with: sudo apt install nbdkit (Debian/Ubuntu) or equivalent"
        exit 1
    fi

    # Check if working directory exists
    if [ ! -d "$WORK_DIR" ]; then
        echo "Error: Working directory $WORK_DIR not found"
        echo "Please run 'create' first"
        exit 1
    fi

    # Create PID directory
    mkdir -p "$WORK_DIR/nbd-pids"

    PORT=10809  # Standard NBD port
    PIDFILE="$WORK_DIR/nbd-pids/nbdkit.pid"
    
    echo "Starting NBD server on port $PORT with all test exports..."
    
    # Build the nbdkit command with multiple exports using the exportname filter
    CMD="nbdkit -v -f -P $PIDFILE -p $PORT --filter=exportname file dir=$WORK_DIR/ exportname-list=explicit exportname-strict=true"
    
    # Add each disk as an export
    for i in $(seq 0 $((NUM_DISKS - 1))); do
        if [ -f "$WORK_DIR/test${i}" ]; then
            CMD="$CMD exportname=test${i}"
        else
            echo "Warning: test${i} not found"
        fi
    done
    
    # Add the file plugin at the end
    echo "run nbdkit command: $CMD"
    
    # Start the server
	eval "$CMD > $WORK_DIR/nbdkit.log 2> $WORK_DIR/nbdkit.err" &
    
    sleep 2  # Give the server time to start
    
    if [ -f "$PIDFILE" ]; then
        echo "NBD server started on port $PORT (PID: $(cat $PIDFILE))"
        echo ""
        echo "=== NBD Server Running ==="
        echo "Available exports on port $PORT:"
        for i in $(seq 0 $((NUM_DISKS - 1))); do
            echo "  - test${i}"
        done
        echo ""
        echo "List exports with: nbd-client -l localhost $PORT"
        for i in $(seq 0 $((NUM_DISKS - 1))); do
            echo "Connect with: nbd-client -N test${i} localhost $PORT /dev/nbd${i}"
        done
        echo "Or use ./ragnar.sh open!"
    else
        echo "Failed to start NBD server"
    fi
}

# Function to stop NBD servers
stop_nbd() {
    echo "=== Stopping NBD server ==="

    PIDFILE="$WORK_DIR/nbd-pids/nbdkit.pid"
    
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        if kill -0 "$PID" 2>/dev/null; then
            echo "Stopping NBD server (PID: $PID)..."
            kill -9 "$PID"
            rm -f "$PIDFILE"
            echo "NBD server stopped"
        else
            echo "NBD server not running, cleaning up PID file..."
            rm -f "$PIDFILE"
        fi
    else
        echo "No NBD server found"
    fi
    
    # Clean up PID directory if empty
    rmdir "$WORK_DIR/nbd-pids" 2>/dev/null || true
}

# Function to show usage
usage() {
    echo "Usage: $0 {create|mount|unmount|destroy|start-nbd|stop-nbd}"
    echo ""
    echo "Commands:"
    echo "  create     - Create new LUKS-encrypted ZFS RAIDZ2 test pool"
    echo "  mount      - Open LUKS devices and import existing pool"
    echo "  unmount    - Export pool and close LUKS devices"
    echo "  destroy    - Remove everything (pool, LUKS devices, files)"
    echo "  start-nbd  - Start NBD servers for the disk images"
    echo "  stop-nbd   - Stop NBD servers"
    echo ""
    echo " Can be used to simualte a ragnar test."
    echo " 1. ./test.sh create"
    echo " 2. ./test.sh unmount"
    echo " 3. ./test.sh start-nbd"
    echo " 4. ./test.sh create"
    echo " 5. On a different computer:
    echo " 	RAGNAR_SERVER=test RAGNAR_KEYFILE=/tmp/zfs-test/test.key ./ragnar.sh open"
    echo " 6. test!"
    echo " 7. On a different computer:
    echo " 	RAGNAR_SERVER=test RAGNAR_KEYFILE=/tmp/zfs-test/test.key ./ragnar.sh close"
    echo " 8. ./test.sh stop-nbd"
    echo " 9. ./test.sh mount"
    echo " 10. inspect!"
    echo " 11. ./test.sh unmount"
    echo " 12. ./test.sh destroy"
    echo ""
    exit 1
}

# Main script logic
case "$1" in
    create)
        create_pool
        ;;
    mount)
        mount_pool
        ;;
    unmount)
        unmount_pool
        ;;
    destroy)
        destroy_pool
        ;;
    start-nbd)
        start_nbd
        ;;
    stop-nbd)
        stop_nbd
        ;;
    *)
        usage
        ;;
esac
