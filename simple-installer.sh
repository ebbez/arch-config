#!/bin/bash

subvol_names=("@ @home @pkg @log @tmp @snapshots @swap")
subvol_mountpoints=("/ /home/ /var/cache/pacman/pkg /var/log /var/tmp /.snapshots /swap")
base_packages="linux linux-firmware base base-devel cryptsetup btrfs-progs"
network_packages="networkmanager ufw"
kde_packages="plasma-meta xdg-desktop-portal-kde xwaylandvideobridge dolphin"
hypr_packages="hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-kde polkit polkit-kde-agent qt5-wayland qt6-wayland gtk3 gtk4 waybar brightnessctl pavucontrol kitty dolphin"
userapps="neovim git man htop"

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
	cryptsetup open $1 root

	mkfs.btrfs /dev/mapper/root

	mount /dev/mapper/root /mnt

	for subvol in $subvol_names; do
		btrfs sub create /mnt/${subvol}
	done;

	unmount /mnt
}

mount_parts() {
	for i in ${!subvol_names[@]}; do
		mount -o noatime,nodiratime,compress=zstd,x-mount.mkdir,subvol="${subvol_names[$i]}" /dev/mapper/root "${subvol_mountpoints[$i]}"
	done;

	mount -o x-mount.mkdir ${1}1 /mnt/efi
}

mount_parts

exit 0

echo -n "Disk to install Arch on: "
read -e -i "/dev/" disk

diskpart=$disk
if [[ $disk =~ /dev/nvme0n[0-9] ]]; then
	diskpart=${disk}p
fi;

echo "Using ${disk} for block device path"
echo "Using ${diskpart} for partition paths"

#partition_disk $disk
#format_disk $disk $diskpart
