#!/bin/bash

declare -r SUBVOL_NAMES=("@ @home @pkg @log @tmp @snapshots @swap")
declare -r SUBVOL_MOUNTPOINTS=("/ /home/ /var/cache/pacman/pkg /var/log /var/tmp /.snapshots /swap")

declare -r BASE_PACKAGES="linux linux-firmware base base-devel cryptsetup btrfs-progs"
declare -r NETWORK_PACKAGES="networkmanager ufw"

declare -r KDE_PACKAGES="plasma-meta xwaylandvideobridge dolphin"

declare -r WAYBAR_PACKGES="waybar ttf-font-awesome ttf-dejavu"
declare -r HYPR_CONTROL_PACKAGES="pavucontrol brightnessctl"
declare -r HYPR_APPS="dolhpin kitty gtk3" # gtk3 was needed otherwise kitty wouldn't launch
declare -r HYPR_PACKAGES="hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-kde xwaylandvideobridge polkit polkit-kde-agent qt6-wayland gtk4 $HYPR_CONTROL_PACKAGES $WAYBAR_PACKAGES $HYPR_APPS"
declare -r USERAPPS="neovim git man htop openssh"
declare -r WEBCORD_SCREENSHARING_FIX="xdg-dessktop-portal-gnome"

partition_disk() {
	# Clear disk partition table and set to GPT format
	sgdisk --zap-all $1

	# Add 1GB EFI partition
	sgdisk --new 0:0:+1G --typecode ef00 $1

	# Add root/LUKS container partition
	sgdisk --new 0:0:0 $1
}


format_disk() {
	mkfs.fat -F 32 ${1}1

	cryptsetup luksFormat ${1}2
	cryptsetup open ${1}2 root

	mkfs.btrfs /dev/mapper/root

	mount /dev/mapper/root /mnt

	for subvol in $SUBVOL_NAMES; do
		btrfs sub create /mnt/${subvol}
	done;

	unmount /mnt
}

mount_parts() {
	for i in ${!SUBVOL_NAMES[@]}; do
		mount -o noatime,nodiratime,compress=zstd,x-mount.mkdir,subvol="${SUBVOL_NAMES[$i]}" /dev/mapper/root "${SUBVOL_MOUNTPOINTS[$i]}"
	done;

	mount -o x-mount.mkdir ${1}1 /mnt/efi
}

exit 0

echo -n "Disk to install Arch on: "
read -e -i "/dev/" disk

disk_part_prefix=$disk
if [[ $disk =~ /dev/nvme0n[0-9] ]]; then
	disk_part_prefix=${disk}p
fi;

echo "Using ${disk} for block device path"
echo "Using ${diskpart} for partition paths"

#partition_disk $disk
#format_disk $disk_part_prefix
#mount_parts $disk_part_prefix

