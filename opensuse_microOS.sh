#!/bin/bash
#
# Script to create and configure a new VM in Proxmox.

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

# Function to check if VM name already exists
vm_name_exists() {
    local name=$1
    qm list | grep -qw "$name"
}

# Prompt the user for a VM name
while true; do
    read -p "Enter a name for the VM (leave blank to use default 'microOS-$VM_ID'): " vm_name

    # Use default name if input is empty
    if [ -z "$vm_name" ]; then
        vm_name="microOS-$VM_ID"
        echo "Using default VM name: $vm_name"
        break
    elif vm_name_exists "$vm_name"; then
        echo "A VM with the name '$vm_name' already exists. Please enter a different name."
    else
        echo "Using VM name: $vm_name"
        break
    fi
done

# Function to check if input is a positive integer
is_positive_integer() {
    [[ $1 =~ ^[0-9]+$ ]] && [ $1 -gt 0 ]
}

# Prompt for CPU cores
while true; do
    read -p "Enter the number of CPU cores (default: 2): " cpu
    if [ -z "$cpu" ]; then
        cpu=2
        echo "Using default CPU cores: $cpu"
        break
    elif is_positive_integer "$cpu"; then
        echo "Using CPU cores: $cpu"
        break
    else
        echo "Invalid input. Please enter a positive integer."
    fi
done

# Prompt for Memory size in GB and convert to MB
while true; do
    read -p "Enter the memory size in GB (e.g., 1 for 1GB, default: 2 for 2GB): " mem_gb
    if [ -z "$mem_gb" ]; then
        mem=2048 # Default 2GB in MB
        echo "Using default memory size: 2GB"
        break
    elif is_positive_integer "$mem_gb"; then
        mem=$((mem_gb * 1024)) # Convert GB to MB
        echo "Using memory size: ${mem_gb}GB (${mem}MB)"
        break
    else
        echo "Invalid input. Please enter a positive integer representing GB."
    fi
done

# Extract bridge names starting with 'vmbr' from /etc/network/interfaces
BRIDGE_NAMES=$(awk '/iface vmbr/ {print $2}' /etc/network/interfaces)

# Check if any bridges were found
if [ -z "$BRIDGE_NAMES" ]; then
    echo "No 'vmbr' bridges found in /etc/network/interfaces."
    exit 1
fi

# Convert the bridge names into an array
BRIDGES=($BRIDGE_NAMES)

# Prompt user to select a bridge
echo "Please select a bridge:"
select virt_bridge in "${BRIDGES[@]}"; do
    # Break if a valid selection is made
    if [[ " ${BRIDGES[*]} " =~ " ${virt_bridge} " ]]; then
        echo "You have selected: $virt_bridge"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Initialize vlan_tag
vlan_tag=""

# Prompt the user for a VLAN tag, only accept numbers between 1-4095
while [[ ! $vlan_tag =~ ^[0-9]+$ ]] || [ $vlan_tag -lt 1 ] || [ $vlan_tag -gt 4095 ]; do
    read -p "Enter VLAN tag (1-4095): " vlan_tag

    # Check if the input is empty
    if [ -z "$vlan_tag" ]; then
        echo "No VLAN tag specified, proceeding without VLAN tag."
        break
    elif [[ ! $vlan_tag =~ ^[0-9]+$ ]] || [ $vlan_tag -lt 1 ] || [ $vlan_tag -gt 4095 ]; then
        echo "Invalid VLAN tag. Please enter a number between 1 and 4095."
    fi
done

# Set VLAN parameter if a valid number is provided
if [[ $vlan_tag =~ ^[0-9]+$ ]]; then
    vlan_parameter="tag=$vlan_tag"
else
    vlan_parameter=""
fi

# Datastore Selection
CFG="/etc/pve/storage.cfg"
if [ ! -r "$CFG" ]; then
    echo "Error: Cannot read $CFG. No storage names found."
    exit 1
fi

stor=()
while IFS= read -r line; do
    [[ $line =~ ^[a-z]+:\ +(.+)$ ]] && stor+=("${BASH_REMATCH[1]}")
done <"$CFG"

echo "Select a datastore:"
select selected_storage in "${stor[@]}"; do
    if [[ " ${stor[*]} " =~ " ${selected_storage} " ]]; then
        echo "You have selected: $selected_storage"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Prompt for VM start at boot-up decision
echo "Do you want to set the VM to start at boot-up?"
select start_at_boot in "Yes" "No"; do
    case $start_at_boot in
    "Yes")
        onboot_setting=1
        echo "VM will be set to start at boot."
        break
        ;;
    "No")
        onboot_setting=0
        echo "VM will not start at boot."
        break
        ;;
    *) echo "Invalid option $REPLY. Please choose either 1 or 2." ;;
    esac
done

# Prompt for converting VM to a template
echo "Do you want to convert this VM into a template?"
read -p "Enter 'y' for yes or 'n' for no (default: no): " convert_to_template
convert_to_template=${convert_to_template,,} # Convert to lowercase

# Define the minimum disk size
MIN_DISK_SIZE=20 # 20 GB

# Prompt the user for the desired disk size
while true; do
    read -p "Enter the desired disk size (minimum ${MIN_DISK_SIZE}G, e.g., 20G, 120G): " disk_size

    # Check if the input matches the format (number followed by G)
    if [[ $disk_size =~ ^[0-9]+G$ ]]; then
        # Extract the number from the input
        size_number=${disk_size%G}

        # Check if the size is at least the minimum required
        if [ $size_number -ge $MIN_DISK_SIZE ]; then
            echo "Disk size set to $disk_size."
            break
        else
            echo "Disk size must be at least ${MIN_DISK_SIZE}G. Please enter a larger size."
        fi
    else
        echo "Invalid format. Please enter a size in the format 'number' followed by 'G' (e.g., 20G)."
    fi
done

current_dir_combustion_script="./combustion/script"
if [ -f "$current_dir_combustion_script" ]; then
    combustion_script_path=$(realpath "$current_dir_combustion_script")
else
    # Prompt for alternative path or skip
    echo "Combustion script not found in the current directory."
    read -p "Enter the full path to your combustion script, or leave blank to continue without it: " user_input_path

    if [ -z "$user_input_path" ]; then
        echo "No combustion script specified. Continuing without combustion script."
        combustion_script_path=""
    elif [ -f "$user_input_path" ]; then
        combustion_script_path=$user_input_path
    else
        echo "Error: Specified combustion script does not exist. Continuing without it."
        combustion_script_path=""
    fi
fi

# Present options to the user
echo "Please select the version of openSUSE MicroOS to download:"
options=("MicroOS - Base System + Container-Host-Installation" "MicroOS - Base System")

select opt in "${options[@]}"; do
    case $opt in
    "MicroOS - Base System + Container-Host-Installation")
        FILE_NAME="openSUSE-MicroOS.x86_64-ContainerHost-kvm-and-xen.qcow2"
        break
        ;;
    "MicroOS - Base System")
        FILE_NAME="openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2"
        break
        ;;
    *) echo "Invalid option $REPLY" ;;
    esac
done

# Define the download URL
DOWNLOAD_URL="https://download.opensuse.org/tumbleweed/appliances/$FILE_NAME"

# Check if the file exists in the current directory
if [ -f "$FILE_NAME" ]; then
    echo "$FILE_NAME exists. Overwriting..."
    rm -f "$FILE_NAME"
fi

# Download the selected version of MicroOS
wget -O "$FILE_NAME" "$DOWNLOAD_URL"

# Create and configure the new VM
qm create $VM_ID --name $vm_name --cores $cpu --memory $mem --net0 virtio,bridge=$virt_bridge,$vlan_parameter --ostype l26
qm importdisk $VM_ID $FILE_NAME $selected_storage
qm set $VM_ID --scsi0 $selected_storage:$VM_ID/vm-$VM_ID-disk-0.raw
qm set $VM_ID --efidisk0 $selected_storage:0
qm set $VM_ID --scsihw virtio-scsi-single --scsi0 $selected_storage:$VM_ID/vm-$VM_ID-disk-0.raw
qm set $VM_ID --bios ovmf
qm set $VM_ID --boot cd --bootdisk scsi0
qm set $VM_ID --scsihw virtio-scsi-single
qm resize $VM_ID scsi0 +$(($size_number - MIN_DISK_SIZE))G
qm set $VM_ID --vga std
qm set $VM_ID --machine q35
qm set $VM_ID --onboot $onboot_setting
qm set $VM_ID --agent enabled=1

# Configure VM with combustion script if it exists
if [ -n "$combustion_script_path" ]; then
    Node_Name=$(awk '$1 != "127.0.0.1" {print $2; exit}' /etc/hosts | cut -d '.' -f 1)
    CONFIG_FILE="/etc/pve/nodes/$Node_Name/qemu-server/$VM_ID.conf"
    echo "args: -fw_cfg name=opt/org.opensuse.combustion/script,file=$combustion_script_path" >>$CONFIG_FILE
fi

qm start $VM_ID

# Wait for VM provisioning to complete
# (This could be a simple delay or a more complex check)
echo "========VM provisioning, please wait=========="
sleep 80

#Template creation if yes
if [[ "$convert_to_template" == "y" ]]; then
    echo "Converting VM to a template. VM will be stopped first."

    # Stop the VM
    qm stop $VM_ID

    # Wait until the VM is completely stopped
    while qm status $VM_ID | grep -q 'running'; do
        echo "Waiting for VM to stop..."
        sleep 5
    done

    # Convert the VM into a template
    qm template $VM_ID
    echo "VM converted to template."
else
    echo "VM will not be converted to a template."
fi

# Remove the -fw_cfg parameter post-provisioning
NODE_NAME=$(hostname)
CONFIG_FILE="/etc/pve/nodes/$NODE_NAME/qemu-server/$VM_ID.conf"
sed -i "/args: -fw_cfg/d" $CONFIG_FILE

# Output the VM ID
echo "VM Created with ID: $VM_ID"
