#!/bin/bash

# Put a lifesign into the log using the name of this script
echo "Start of htz_include_volume.sh" | tee -a /var/log/cloud-init.log

# Define base mount directory for the first volume. 
# (Note: this script only considers the first volume)
DEFAULT_BASE_MOUNT="/mnt/data"


# List of directories to symlink to the first detected volume
DEFAULT_SYMLINK_PATHS=(
    "/var/lib/docker"
)

# Read environment variables for customization
BASE_MOUNT=${BASE_MOUNT:-$DEFAULT_BASE_MOUNT}
SYMLINK_PATHS=(${SYMLINK_PATHS:-${DEFAULT_SYMLINK_PATHS[@]}})

# Detect Hetzner Cloud volumes
VOLUMES=($(ls /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null))

if [ ${#VOLUMES[@]} -eq 0 ]; then
    echo "No Hetzner Cloud Volumes found." | tee -a /var/log/cloud-init.log
    echo "End (error) of htz_include_volume.sh" | tee -a /var/log/cloud-init.log
    exit 0
fi

echo "Found ${#VOLUMES[@]} Hetzner Cloud volumes: ${VOLUMES[*]}" | tee -a /var/log/cloud-init.log

# Process first detected volume
DEVICE="${VOLUMES[0]}"
MOUNT_POINT="${BASE_MOUNT}"
LABEL="HCVolume-0"

# Ensure mount directory exists
mkdir -p "$MOUNT_POINT"

# Detect existing filesystem type
FS_TYPE=$(blkid -s TYPE -o value "$DEVICE")

if [ -z "$FS_TYPE" ]; then
    echo "Formatting $DEVICE as ext4 with label $LABEL..." | tee -a /var/log/cloud-init.log
    mkfs.ext4 -L "$LABEL" "$DEVICE"
    FS_TYPE="ext4"
else
    echo "$DEVICE is already formatted as $FS_TYPE." | tee -a /var/log/cloud-init.log
fi

# Get UUID of the device
UUID=$(blkid -s UUID -o value "$DEVICE")

# Add to /etc/fstab if not already present
if ! grep -q "$UUID" /etc/fstab; then
    echo "Adding $DEVICE (UUID=$UUID, FS=$FS_TYPE) to /etc/fstab..." | tee -a /var/log/cloud-init.log
    echo "UUID=$UUID  $MOUNT_POINT  $FS_TYPE  defaults,nofail  0  2" >> /etc/fstab
fi

# Mount the volume
mount "$MOUNT_POINT"
echo "$DEVICE mounted at $MOUNT_POINT" | tee -a /var/log/cloud-init.log

# Ensure directory for symlinked paths exists
SYMLINK_TARGET_DIR="$MOUNT_POINT/"
mkdir -p "$SYMLINK_TARGET_DIR"

# Process each path in the SYMLINK_PATHS list
for TARGET_PATH in "${SYMLINK_PATHS[@]}"; do
    SYMLINK_TARGET="$SYMLINK_TARGET_DIR$(echo "$TARGET_PATH" | sed 's|/|_|g')"

    # Ensure parent directories exist
    PARENT_DIR=$(dirname "$TARGET_PATH")
    mkdir -p "$PARENT_DIR"

    if [ -d "$TARGET_PATH" ] || [ -f "$TARGET_PATH" ]; then
        echo "Preserving attributes of $TARGET_PATH before moving..." | tee -a /var/log/cloud-init.log

        # Preserve ownership, permissions, ACLs, attributes
        OWNER=$(stat -c "%u" "$TARGET_PATH")
        GROUP=$(stat -c "%g" "$TARGET_PATH")
        PERMS=$(stat -c "%a" "$TARGET_PATH")

        if command -v getfacl &>/dev/null; then
            getfacl -p "$TARGET_PATH" > /tmp/acl_backup.txt
        fi

        if command -v lsattr &>/dev/null; then
            ATTRS=$(lsattr -d "$TARGET_PATH" | awk '{print $1}')
        fi

        if command -v ls -Z &>/dev/null; then
            CONTEXT=$(ls -Z "$TARGET_PATH" | awk '{print $1}')
        fi

        echo "Moving $TARGET_PATH to $SYMLINK_TARGET..." | tee -a /var/log/cloud-init.log
        mv "$TARGET_PATH" "$SYMLINK_TARGET"
    else
        echo "Creating $SYMLINK_TARGET for $TARGET_PATH..." | tee -a /var/log/cloud-init.log
        mkdir -p "$SYMLINK_TARGET"
    fi

    # Restore ownership & permissions
    chown "$OWNER:$GROUP" "$SYMLINK_TARGET"
    chmod "$PERMS" "$SYMLINK_TARGET"

    # Restore ACLs if backed up
    if [ -f /tmp/acl_backup.txt ]; then
        setfacl --restore=/tmp/acl_backup.txt 2>/dev/null
        rm /tmp/acl_backup.txt
    fi

    # Restore file attributes
    if [ -n "$ATTRS" ]; then
        chattr "$ATTRS" "$SYMLINK_TARGET" 2>/dev/null
    fi

    # Restore SELinux context
    if [ -n "$CONTEXT" ]; then
        chcon "$CONTEXT" "$SYMLINK_TARGET" 2>/dev/null
    fi

    # Create symlink
    ln -sfn "$SYMLINK_TARGET" "$TARGET_PATH"
    echo "Created symlink: $TARGET_PATH -> $SYMLINK_TARGET" | tee -a /var/log/cloud-init.log
done

# Put a lifesign into the log using the name of this script
echo "End of htz_include_volume.sh" | tee -a /var/log/cloud-init.log
