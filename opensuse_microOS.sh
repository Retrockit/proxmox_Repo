#!/bin/bash

# Find an available VM ID
MAX_VM_ID=1000 # Set a maximum ID to avoid an infinite loop
for ((VM_ID = 100; VM_ID <= MAX_VM_ID; VM_ID++)); do
    if ! qm status $VM_ID >/dev/null 2>&1; then
        # If qm status command fails, the VM ID is not in use
        echo "Found available VM ID: $VM_ID"
        break
    fi
done

if [ $VM_ID -gt $MAX_VM_ID ]; then
    echo "No available VM ID found up to $MAX_VM_ID"
    exit 1
fi

# Define the file name and download URL
FILE_NAME="openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2"
DOWNLOAD_URL="https://download.opensuse.org/tumbleweed/appliances/$FILE_NAME"

# Check if the file exists in the current directory
if [ -f "$FILE_NAME" ]; then
    echo "$FILE_NAME exists. Overwriting..."
    rm -f "$FILE_NAME"
fi

# Download the file (overwrite if already exists)
wget -O "$FILE_NAME" "$DOWNLOAD_URL"

# Create and configure the new VM
qm create $VM_ID --name microos --cores 4 --memory 4096 --net0 virtio,bridge=vmbr1,tag=20 --ostype l26
qm importdisk $VM_ID $FILE_NAME local-btrfs
qm set $VM_ID --scsi0 local-btrfs:$VM_ID/vm-$VM_ID-disk-0.raw
qm set $VM_ID --efidisk0 local-btrfs:0
qm set $VM_ID --scsihw virtio-scsi-single --scsi0 local-btrfs:$VM_ID/vm-$VM_ID-disk-0.raw,size=120G
qm set $VM_ID --ide2 local-btrfs:iso/combustion.iso,media=cdrom
qm set $VM_ID --bios ovmf
qm set $VM_ID --boot cd --bootdisk scsi0
qm set $VM_ID --scsihw virtio-scsi-single
qm set $VM_ID --vga std
qm set $VM_ID --machine q35 # Replace VERSION with the actual version

# Extract the hostname and construct the configuration file path
Node_Name=$(awk '$1 != "127.0.0.1" {print $2; exit}' /etc/hosts | cut -d '.' -f 1)
CONFIG_FILE="/etc/pve/nodes/$Node_Name/qemu-server/$VM_ID.conf"
echo "args: -fw_cfg name=opt/org.opensuse.combustion/script,file=/root/build_vm/combustion/script" >>$CONFIG_FILE

qm start $VM_ID

# Import the downloaded disk image into Proxmox

# Stop the VM and convert the VM into a template
qm stop $VM_ID
qm template $VM_ID

# Output the VM ID
echo "VM Created with ID: $VM_ID"

