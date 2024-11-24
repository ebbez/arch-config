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
# But leave it being amd-ucode for now since AMD rocks

declare -r DE_PACKAGES="
	plasma 
	sddm 
	kitty
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

partition_disk() {
	local disk=$1

	# Clear disk partition table and set to GPT format
	sgdisk --zap-all $disk

	# Create 1GB EFI partition
	sgdisk --new 0:0:+1G --typecode 0:ef00 $disk

	# Create root/LUKS container partition (0:0:0 are defaults <order>:<start>:<end>, in this case 2:1G:remainder of the disk)
	sgdisk --new 0:0:0 $disk
}


format_disk() {
	local partition_path_prefix=$1 # e.g. /dev/sda or /dev/nvme0n1p 
	local swap_size=$2 # e.g. "" or "8G"
	local enable_disk_encryption=$3 # e.g. "Y", "y", "n", "N", "yes", "no"
	local root_partition="${partition_path_prefix}2" # e.g. /dev/nvme0n1p2 or /dev/mapper/root

	# Format EFI partition, make it (V)FAT32
	mkfs.fat -F 32 ${partition_path_prefix}1

	# Encrypt and open root partition
	if [[ $enable_disk_encryption =~ ^[Yy]$ ]]; then
		cryptsetup luksFormat ${root_partition}
		cryptsetup open ${root_partition} root
		root_partition="/dev/mapper/root"
	fi

	# Format root partition, make it Btrfs
	mkfs.btrfs $root_partition

	# Mount root partition (top-level volume) to create subvolumes
	mount $root_partition /mnt

	# Create flat Btrfs layout
	for subvol in $SUBVOL_NAMES; do
		btrfs subvolume create /mnt/${subvol}
	done;

	if [ $swap_size != "" ]; then
		btrfs subvolume create /mnt/@swap
		btrfs filesystem mkswapfile --size $swap_size /mnt/@swap/swapfile
	fi

	# Unmount top-level volume to free up /mnt
	umount /mnt
}

mount_subvolumes() {
	local partition_path_prefix=$1
	local swap_size=$2
	local root_partition=${partition_path_prefix}2
	
	if [ -e /dev/mapper/root ]; then 
		root_partition="/dev/mapper/root"; 
	fi

	for i in ${!SUBVOL_NAMES[@]}; do
		# noatime, nodiratime => do not keep track of file and directory access times ("when they have been accessed/opened/edited")
		# compress=zstd => opportunistic compression using zstd (fast) compression algorithm
		# (USE compress-force INSTEAD OF compress TO FORCE COMPRESSION ALWAYS)
		# subvol=x => mount the x subvolume from the top-level Btrfs volume/partition 
		mount -o noatime,nodiratime,compress=zstd,x-mount.mkdir,subvol="${SUBVOL_NAMES[$i]}" "${root_partition}" "/mnt${SUBVOL_MOUNTPOINTS[$i]}"
	done

	if [ $swap_size != "" ]; then
		mount -o noatime,nodiratime,x-mount.mkdir,subvol=@swap "${root_partition}" /mnt/swap
		swapon /mnt/swap/swapfile
	fi

	# Mount the EFI partition
	mount -o x-mount.mkdir ${partition_path_prefix}1 /mnt/efi
}

achrt() {
	arch-chroot /mnt "$@"
}

auchrt() {
	arch-chroot -u $user /mnt/home/$user "$@"
}

install_base() {
	local hostname=$1
	local user=$2
	local partition_path_prefix=$3
	local swap_size=$4
	local root_partition=${partition_path_prefix}2

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
	mkdir -p /mnt/efi/EFI/Linux
	achrt sed -i 's/\/boot\/EFI\//\/efi\/EFI\//g' /etc/mkinitcpio.d/linux.preset

	# Replace Linux/arch-linux.efi to BOOT/bootx64.efi
	mkdir -p /mnt/efi/EFI/Boot
	achrt sed -i 's/Linux\/arch-linux.efi/Boot\/Bootx64.efi/g' /etc/mkinitcpio.d/linux.preset

	# Regenerate initramfs in UKI format and delete (cleanup unused) old initrds
	achrt mkinitcpio -P
	achrt rm /boot/initramfs*

	achrt echo $1 > /etc/hostname

	achrt sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers
	achrt useradd -m ebbe -G wheel
	achrt passwd ebbe

	achrt pacman -Syu $DE_PACKAGES $USER_PACKAGES

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

	achrt mkdir /etc/cmdline.d
	if [ -e /dev/mapper/root ]; then
		achrt "echo \"cryptdevice=UUID=\$(blkid -s UUID -o value ${root_partition})=root root=/dev/mapper/root\" > /etc/cmdline.d/root.conf"
	else
		achrt "echo root=${root_partition} > /etc/cmdline.d/root.conf"
	fi

	achrt "echo \" rootflags=subvol=@ rw rootfstype=btrfs\" >> /etc/cmdline.d/root.conf"

	if [ "${swap_size}" = "" ]; then
		# ENABLE ZRAM
		achrt "echo zswap.enabled=0 > /etc/cmdline.d/zram.conf"
	fi
}

##### MAIN #####
echo -n "Disk to install Arch on: "
read -e -i "/dev/" disk

partition_path_prefix=$disk
if [[ $disk =~ /dev/nvme0n[0-9] ]]; then
	# Append 'p' to the disk device path if nvme because all partition paths arre suffixed with p
	partition_path_prefix=${disk}p
fi;

echo "Using ${disk} for block device path"
echo "Using ${partition_path_prefix} for partition paths"

partition_disk ${disk}

read -p "Swap size (e.g. '12G') or leave empty for zram: " swap_size
read -p "Enable disk encryption? (y/n)" enable_encryption
format_disk "${partition_path_prefix}" "${swap_size}" "${enable_encryption}" 
mount_subvolumes "${partition_path_prefix}" "${swap_size}"

read -p "Hostname: " hostname
read -p "Username: " username
install_base $hostname $username $partition_path_prefix $swap_size
