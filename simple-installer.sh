#!/bin/bash

declare -r SUBVOL_NAMES=("@ @home @pkg @log @tmp @snapshots @swap")
declare -r SUBVOL_MOUNTPOINTS=("/ /home/ /var/cache/pacman/pkg /var/log /var/tmp /.snapshots /swap")

declare -r BASE_PACKAGES="linux linux-firmware base base-devel cryptsetup btrfs-progs"
declare -r NENTWORK_PACKAGES="networkmanager ufw"
declare -r KDE_PACKAGES="plasma-meta xdg-desktop-portal-kde xwaylandvideobridge dolphin"
declare -r HYPR_PACKAGES="hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-kde polkit polkit-kde-agent qt5-wayland qt6-wayland gtk3 gtk4 waybar brightnessctl pavucontrol kitty dolphin"
declare -r USERAPPS="neovim git man htop"

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

