#!/bin/bash

declare -r SUBVOL_NAMES=("@ @home @pkg @log @tmp @snapshots @swap")
declare -r SUBVOL_MOUNTPOINTS=("/ /home/ /var/cache/pacman/pkg /var/log /var/tmp /.snapshots /swap")

declare -r BASE_PACKAGES="linux linux-firmware base base-devel cryptsetup btrfs-progs git neovim"

partition_disk() {
	# Clear disk partition table and set to GPT format
	sgdisk --zap-all $1

	# Create 1GB EFI partition
	sgdisk --new 0:0:+1G --typecode ef00 $1

	# Create root/LUKS container partition (0:0:0 are defaults <order>:<start>:<end>, in this case 2:1G:remainder of the disk)
	sgdisk --new 0:0:0 $1
}


#;
# format_disk()
# formats partitions on the disk
# @param disk path with partition suffix if applicable (/dev/nvme0n1p for example)
# @return void
#"
format_disk() {
	# Format EFI partition, make it (V)FAT32
	mkfs.fat -F 32 ${1}1

	# Encrypt and open root partition
	cryptsetup luksFormat ${1}2
	cryptsetup open ${1}2 root

	# Format root partition, make it Btrfs
	mkfs.btrfs /dev/mapper/root

	# Mount root partition (top-level volume) to create subvolumes
	mount /dev/mapper/root /mnt

	# Create flat Btrfs layout
	for subvol in $SUBVOL_NAMES; do
		btrfs sub create /mnt/${subvol}
	done;

	# Unmount top-level volume to free up /mnt
	unmount /mnt
}


mount_subvolumes() {
	for i in ${!SUBVOL_NAMES[@]}; do
		# noatime, nodiratime => do not keep track of file and directory access times ("when they have been accessed/opened/edited")
		# compress=zstd => opportunistic compression using zstd (fast) compression algorithm
		# (USE compress-force INSTEAD OF compress TO FORCE COMPRESSION ALWAYS)
		# subvol=x => mount the x subvolume from the top-level Btrfs volume/partition 
		mount -o noatime,nodiratime,compress=zstd,x-mount.mkdir,subvol="${SUBVOL_NAMES[$i]}" /dev/mapper/root "${SUBVOL_MOUNTPOINTS[$i]}"
	done;

	# Mount the EFI partition
	mount -o x-mount.mkdir ${1}1 /mnt/efi
}


install_base() {
	pacstrap /mnt $BASE_PACKAGES 

}

#### MAIN ####
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

