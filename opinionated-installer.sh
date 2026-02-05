#!/bin/bash

###### CONFIG #######

### SECTIONS ###
declare -r SECTIONS=(
		partition_disk 
		format_disk 
		mount_subvolumes 
		install_base 
		set_hostname 
		set_locale 
		set_uki 
		set_kernel_parameters 
		set_user install_de 
		install_user_apps 
		install_aur_helper 
		install_aur_packages 
		set_en_eu_locale set_secure_boot
	)

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

##### INSTALLER HELPER FUNCTIONS #####
function prompt_disk {

	echo -n "Disk: "
	read -e -i "/dev/" disk

	partition_path_prefix=$disk
	if [[ $disk =~ /dev/nvme0n[0-9] ]]; then
		# Append 'p' to the disk device path if nvme because all partition paths arre suffixed with p
		partition_path_prefix=${disk}p
	fi
}

function ensure_disk {
	if [ -n $disk ]; then return; fi

	read -p "Do you already have a partitioned disk? (y/n): " have_partitioned_disk
	if [[ $have_partitioned_disk =~ ^[Yy]$ ]]; then
		prompt_disk
	else
		partition_disk
	fi
}

function ensure_root_partition {
	if [ -n $root_partition ]; then return; fi

	read -p "Do you already have a formatted disk? (y/n): " have_formatted_disk
	if [[ $have_formatted_disk =~ ^[Yy]$ ]]; then
		if [ -z $disk ]; then
			prompt_disk
		fi

		read -p "Is the root partition encrypted? (y/n): " enable_disk_encryption
		if [[ $enable_disk_encryption =~ ^[Yy]$ ]]; then
			cryptsetup open "${partition_path_prefix}2" root
			root_partition="/dev/mapper/root"
		else
			root_partition="${partition_path_prefix}2"
		fi

	else
		echo "Please re-run the installer to partition and format the disk"
	fi
}

##### INSTALLER SECTIONS #####
function partition_disk {
	echo "
	Partition disk
	> Will wipe and set disk partition table type to GPT
	Partition #1: 1GB EFI partition
	Partition #2: Remaining/leftover space for root partition
	"
	echo

	prompt_disk

	# Clear disk partition table and set to GPT format
	sgdisk --zap-all $disk

	# Create 1GB EFI partition
	sgdisk --new 0:0:+1G --typecode 0:ef00 $disk

	# Create root/LUKS container partition (0:0:0 are defaults <order>:<start>:<end>, in this case 2:1G:remainder of the disk)
	sgdisk --new 0:0:0 $disk
}


function format_disk {
	ensure_disk

	# Format EFI partition, make it (V)FAT32
	mkfs.fat -F 32 ${partition_path_prefix}1

	# Encrypt and open root partition
	if [[ $enable_disk_encryption =~ ^[Yy]$ ]]; then
		cryptsetup luksFormat ${root_partition}
		cryptsetup open ${root_partition} root
		root_partition="/dev/mapper/root"
	else
		root_partition="${partition_path_prefix}2"
	fi

	# Format root partition, make it Btrfs
	mkfs.btrfs $root_partition

	# Mount root partition (top-level volume) to create subvolumes
	mount $root_partition /mnt

	# Create flat Btrfs layout
	for subvol in $SUBVOL_NAMES; do
		btrfs subvolume create /mnt/${subvol}
	done;

	read -p "Swap size (e.g. '12G', or leave empty to skip): " swap_size
	if [ $swap_size != "" ]; then
		btrfs subvolume create /mnt/@swap
		btrfs filesystem mkswapfile --size "${swap_size}" /mnt/@swap/swapfile
	fi

	# Unmount top-level volume to free up /mnt
	umount /mnt
}

function mount_subvolumes {
	ensure_root_partition

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

function install_base {
	ensure_root_partition

	pacstrap /mnt $BASE_PACKAGES 

	genfstab -U /mnt > /mnt/etc/fstab
}

function set_locale {
	ensure_root_partition

	arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
	arch-chroot /mnt timedatectl set-ntp true
	arch-chroot /mnt hwclock --systohc

	arch-chroot sed -i '/en_US.UTF-8/s/^#//g' /etc/locale.gen
	arch-chroot /mnt locale-gen
	arch-chroot /mnt /bin/bash -c "echo LANG=en_US.UTF_8 > /etc/locale.conf"
}

function set_uki {
	ensure_root_partition
	
	# Comment out the *_image= lines
	sed -i '/default_image=/s/^/#/g' /mnt/etc/mkinitcpio.d/linux.preset
	sed -i '/fallback_image=/s/^/#/g' /mnt/etc/mkinitcpio.d/linux.preset

	# Uncomment the UKI lines
	sed -i '/default_uki/s/^#//g' /mnt/etc/mkinitcpio.d/linux.preset
	sed -i '/fallback_uki/s/^#//g' /mnt/etc/mkinitcpio.d/linux.preset
	sed -i '/default_options/s/^#//g' /mnt/etc/mkinitcpio.d/linux.preset

	# Replace /boot/EFI with /efi/EFI
	arch-chroot /mnt mkdir -p /efi/EFI/Linux
	sed -i 's/\/boot\/EFI\//\/efi\/EFI\//g' /mnt/etc/mkinitcpio.d/linux.preset

	# Replace Linux/arch-linux.efi to BOOT/bootx64.efi
	arch-chroot /mnt mkdir -p /efi/EFI/Boot
	sed -i 's/Linux\/arch-linux.efi/Boot\/Bootx64.efi/g' /mnt/etc/mkinitcpio.d/linux.preset

	# Regenerate initramfs in UKI format and delete (cleanup unused) old initrds
	arch-chroot /mnt mkinitcpio -P
	rm /mnt/boot/initramfs*
}


function set_kernel_parameters {
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

function set_hostname {
	echo $1 > /etc/hostname
}

function set_user {
	sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers
	useradd -m ebbe -G wheel
	passwd ebbe
}

function install_de {
	pacstrap /mnt $DE_PACKAGES
}

function install_user_apps {
	pacstrap /mnt $USER_PACKAGES
}

function install_aur_helper {
	arch-chroot /mnt/home/$user -u $user /bin/bash -c "git clone https://aur.archlinux.org/yay.git"
	arch-chroot /mnt/home/$user -u $user /bin/bash -c "cd yay && makepkg -si"
}

function install_aur_packages {
	auchrt yay -S $AUR_PACKAGES
}

function set_en_eu_locale {
	achrt sed -i '/en_NL.UTF-8/s/^#//g' /etc/locale.gen
	achrt locale-gen
	achrt echo LANG=en_NL.UTF_8 > /etc/locale.conf
}

function set_secure_boot {
	achrt sbctl create-keys
	achrt sbctl enroll-keys -m

	achrt sbctl sign -s /efi/EFI/Boot/Bootx64.efi
	achrt sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi
}


function full_install {
	echo "Hello world"
}

function step_install {
	echo "These steps are available for installion:"
	echo
	for i in ${!SECTIONS[@]}; do
		echo "${i}. ${SECTIONS[$i]}"
	done

	read -r -p "Enter the number of step : " stepno

	stepno=$[$stepno-1]
	while [ $stepno -lt ${#SECTIONS[*]} ]
	do
		${SECTIONS[$stepno]}
		stepno=$[$stepno+1]
	done
}

function main {
	step_install
}

main