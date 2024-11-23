#!/bin/bash

###### CONFIG #######

### SUBVOLUMES ###
declare -r SUBVOL_NAMES=("@ @home @pkg @log @tmp @snapshots")
declare -r SUBVOL_MOUNTPOINTS=("/ /home/ /var/cache/pacman/pkg /var/log /var/tmp /.snapshots")

### PACKAGES ###
# TODO: Detect which microcode is needed
declare -r BASE_PACKAGES="
	linux 
	linux-firmware 
	amd-ucode 
	base 
	base-devel 
	cryptsetup
	btrfs-progs
	efibootmgr
	networkmanager 
	git 
	neovim 
	sbctl
	"
# But leave at amd-ucode for now since AMD rocks
#
declare -r DE_PACKAGES="
	plasma 
	sddm 
	konsole 
	dolphin 
	kdeconnect 
	filelight 
	isoimagewriter
	"

declare -r USER_PACKAGES="
	htop 
	libreoffice-still 
	syncthing 
	keepassxc
	thunderbird"

declare -r AUR_PACKAGES="
	librewolf-bin
	vesktop
	android-studio
	vscodium-bin
	locale-en-nl-git
	"


##### INSTALLER SECTIONS #####

#;
# partition_disk()
# sets up the partition table on the disk
# @param disk device path
# @return void
#"
partition_disk() {
	# Clear disk partition table and set to GPT format
	sgdisk --zap-all $1

	# Create 1GB EFI partition
	sgdisk --new 0:0:+1G --typecode 0:ef00 $1

	# Create root/LUKS container partition (0:0:0 are defaults <order>:<start>:<end>, in this case 2:1G:remainder of the disk)
	sgdisk --new 0:0:0 $1
}


#;
# format_disk()
# formats partitions on the disk
# @param disk device path with partition suffix if applicable (/dev/nvme0n1p for example)
# @param swap size
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
		btrfs subvolume create /mnt/${subvol}
	done;

	# IF CREATE SWAP
	btrfs subvolume create /mnt/@swap
	btrfs filesystem mkswapfile --size $2 /mnt/swap/swapfile

	# Unmount top-level volume to free up /mnt
	unmount /mnt
}

#;
# mount_subvolumes()
# mounts the subvolumes of the root Btrfs partition
# @param swap size
# @return void
#"
mount_subvolumes() {
	for i in ${!SUBVOL_NAMES[@]}; do
		# noatime, nodiratime => do not keep track of file and directory access times ("when they have been accessed/opened/edited")
		# compress=zstd => opportunistic compression using zstd (fast) compression algorithm
		# (USE compress-force INSTEAD OF compress TO FORCE COMPRESSION ALWAYS)
		# subvol=x => mount the x subvolume from the top-level Btrfs volume/partition 
		mount -o noatime,nodiratime,compress=zstd,x-mount.mkdir,subvol="${SUBVOL_NAMES[$i]}" /dev/mapper/root "${SUBVOL_MOUNTPOINTS[$i]}"
	done;

	# IF SWAP
	mount -o noatime,nodiratime,subvol=@swap /dev/mapper/root /mnt/swap
	swapon /mnt/swap/swapfile

	# Mount the EFI partition
	mount -o x-mount.mkdir ${1}1 /mnt/efi
}

achrt() {
	arch-chroot /mnt "$@"
}

auchrt() {
	arch-chroot -u ebbe /mnt "$@"
}

#;
# mount_subvolumes()
# mounts the subvolumes of the root Btrfs partition
# @parameter hostname
# @return void
#"
install_base() {
	pacstrap /mnt $BASE_PACKAGES 

	genfstab -U /mnt > /mnt/etc/fstab

	achrt ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
	achrt timedatectl set-ntp true
	achrt hwclock --systohc

	achrt sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
	achrt locale-gen
	achrt echo LANG=en_US.UTF_8 > /etc/locale.conf

	# Comment out the *_image= lines
	achrt sed -i '/default_image=/s/^/#/g' /etc/mkinitcpio.d/linux.preset
	achrt sed -i '/fallback_image=/s/^/#/g' /etc/mkinitcpio.d/linux.preset

	# Uncomment the UKI lines
	achrt sed -i '/default_uki/s/^#//g' /etc/mkinitcpio.d/linux.preset
	achrt sed -i '/fallback_uki/s/^#//g' /etc/mkinitcpio.d/linux.preset
	achrt sed -i '/default_options/s/^#//g' /etc/mkinitcpio.d/linux.preset

	# Replace /boot/EFI with /efi/EFI
	mkdir -p /efi/EFI/Linux
	achrt sed -i 's/\/boot\/EFI\//\/efi\/EFI\//g' /etc/mkinitcpio.d/linux.preset

	# Replace Linux/arch-linux.efi to BOOT/bootx64.efi
	mkdir -p /efi/EFI/Boot
	achrt sed -i 's/Linux\/arch-linux.efi/Boot\/Bootx64.efi/g' /etc/mkinitcpio.d/linux.preset

	# Regenerate initramfs in UKI format and delete (cleanup unused) old initrds
	achrt mkinitcpio -P
	achrt rm /boot/initramfs*

	achrt echo $1 > /etc/hostname

	achrt sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers
	achrt useradd -m ebbe -G wheel
	achrt passwd ebbe

	auchrt git clone https://aur.archlinux.org/yay.git
	auchrt cd yay && makepkg -si

	auchrt yay -S $AUR_PACKAGES
	achrt sed -i '/en_NL.UTF-8/s/^#//g' /etc/locale.gen
	achrt locale-gen
	achrt echo LANG=en_NL.UTF_8 > /etc/locale.conf

	achrt sbctl create-keys
	achrt sbctl enroll-keys -m

	achrt sbctl sign -s /efi/EFI/Boot/Bootx64.efi
achrt sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi
}

##### MAIN #####
echo -n "Disk to install Arch on: "
read -e -i "/dev/" disk

disk_part_prefix=$disk
if [[ $disk =~ /dev/nvme0n[0-9] ]]; then
	# Append 'p' to the disk device path if nvme because all partition paths arre suffixed with p
	disk_part_prefix=${disk}p
fi;

echo "Using ${disk} for block device path"
echo "Using ${diskpart} for partition paths"

partition_disk $disk

read -i "Swap size (e.g. '12G'): " swapsize
format_disk $disk_part_prefix swapsize
mount_subvolumes $disk_part_prefix swapsize
install_base
