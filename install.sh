#!/bin/bash

set -e

export LANG="C"

SERVER_HOSTNAME="debserv"
SERVER_DOMAIN="local"
SERVER_IP="192.168.0.105"
SERVER_NETMASK="255.255.255.0"
SERVER_NETWORK="192.168.0.0"
SERVER_BROADCAST="192.168.0.254"
SERVER_GATEWAY="192.168.0.1"
SSH_PUBKEY="id_rsa.pub"
RAID_PASSWORD="secret"

function partition {
    if [ -z "$1" ]; then
        exit 1
    fi
    
    parted -a optimal --script $1 -- mklabel gpt
    parted -a optimal --script $1 -- mkpart BOOT_GRUB 2 4
    parted -a optimal --script $1 -- mkpart GRUB_FILES 4 512MB
    parted -a optimal --script $1 -- mkpart RAID 512MB 100%
    parted -a optimal --script $1 -- set 1 bios_grub on
    parted -a optimal --script $1 -- set 2 boot on
    parted -a optimal --script $1 -- set 3 raid on
}

function uuid {
    if [ ! -e "$1" ]; then
        exit 1
    fi

    echo `blkid $1 | cut -d '"' -f 2`
}

red=`tput setaf 1`
green=`tput setaf 2`
reset=`tput sgr0`

while true
do
    read -p "${red}Warning!${reset} Do you really want to continue? " yn
    case $yn in
        [Yy]*) break;;
        [Nn]*) exit;; 
        *) echo "yes/no";;
    esac
done

if [ ! -e "$SSH_PUBKEY" ]
then
    echo "SSH pubkey missing..."
    exit 1
fi

if mount | grep -q "/mnt/debian/boot"
then
    umount /mnt/debian/boot
fi

if mount | grep -q "/mnt/debian"
then
    umount /mnt/debian
fi


# Deactivate old volume groups
if vgdisplay | grep -q "vg0"
then
    vgchange -an
    vgremove -f vg0
fi

if [ -e /dev/mapper/raid ]
then
    cryptsetup luksClose /dev/mapper/raid
fi

# Remove old RAID md0
if cat /proc/mdstat | grep -q md0
then
    mdadm --stop /dev/md0
    mdadm --zero-superblock /dev/sda2
    mdadm --zero-superblock /dev/sdb2
fi

# Remove old RAID md1
if cat /proc/mdstat | grep -q md1
then
    mdadm --stop /dev/md1
    mdadm --zero-superblock /dev/sda3
    mdadm --zero-superblock /dev/sdb3
fi

partition /dev/sda
partition /dev/sdb

mdadm --create -n 2 -l 1 --run /dev/md0 /dev/sd[ab]2
mdadm --create -n 2 -l 1 --run /dev/md1 /dev/sd[ab]3

mkfs.ext3 /dev/md0
echo -n "$RAID_PASSWORD" | cryptsetup -c aes-xts-plain64:sha256 -s 512 -y luksFormat /dev/md1

echo -n "$RAID_PASSWORD" | cryptsetup luksOpen /dev/md1 raid

pvcreate /dev/mapper/raid
vgcreate vg0 /dev/mapper/raid

lvcreate -L 1G -n swap vg0
lvcreate -L 3G -n root vg0

mkswap /dev/vg0/swap
mkfs.ext4 /dev/vg0/root

UUID_MD0=$(uuid /dev/md0)
UUID_MD1=$(uuid /dev/md1)
UUID_ROOT=$(uuid /dev/vg0/root)
UUID_SWAP=$(uuid /dev/vg0/swap)

mkdir -p /mnt/debian
mount /dev/vg0/root /mnt/debian
mkdir /mnt/debian/boot
mount /dev/md0 /mnt/debian/boot

debootstrap --arch amd64 wheezy /mnt/debian 

mount -t proc none /mnt/debian/proc
mount -o bind /dev /mnt/debian/dev
mount -o bind /dev/pts /mnt/debian/dev/pts
mount -o bind /sys /mnt/debian/sys

cp /etc/resolv.conf /mnt/debian/etc/resolv.conf
cp /etc/mtab /mnt/debian/etc/mtab
mkdir -p /mnt/debian/etc/initramfs-tools/hooks/
cp ./scripts/mount_cryptroot /mnt/debian/etc/initramfs-tools/hooks/mount_cryptroot
mkdir -p /mnt/debian/etc/initramfs-tools/scripts/local-top/
cp ./scripts/cryptraid /mnt/debian/etc/initramfs-tools/scripts/local-top/cryptraid
cp $SSH_PUBKEY /mnt/debian/root/id_rsa.pub
cp debian.cfg /mnt/debian/root/debian.cfg

cat << EOF > /mnt/debian/setup.sh
echo "
UUID=$UUID_ROOT / ext4 defaults 0 0
UUID=$UUID_MD0 /boot ext3 defaults 0 1
UUID=$UUID_SWAP none swap sw 0 0
proc /proc proc defaults 0 0
sys /sys sysfs defaults 0 0
" > /etc/fstab

echo $SERVER_HOSTNAME > /etc/hostname

echo "127.0.0.1 localhost
127.0.1.1 $SERVER_HOSTNAME
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
" > /etc/hosts

echo "auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
address $SERVER_IP
netmask $SERVER_NETMASK
gateway $SERVER_GATEWAY
" > /etc/network/interfaces

echo "#deb     http://mirror.hetzner.de/debian/packages wheezy main contrib non-free
#deb     http://mirror.hetzner.de/debian/security wheezy/updates main contrib non-free

deb 	http://cdn.debian.net/debian/ wheezy main non-free contrib
deb-src http://cdn.debian.net/debian/ wheezy main non-free contrib

deb     http://security.debian.org/  wheezy/updates  main contrib non-free
deb-src http://security.debian.org/  wheezy/updates  main contrib non-free
" > /etc/apt/sources.list

dpkg-reconfigure tzdata

apt-get update

apt-get install -y aptitude openssh-server locales
apt-get install -y firmware-realtek linux-image-amd64
apt-get install -y cryptsetup lvm2 mdadm

apt-get install -y busybox dropbear

cat ~/id_rsa.pub > /etc/initramfs-tools/root/.ssh/authorized_keys

update-rc.d ssh defaults

/usr/share/mdadm/mkconf > /etc/mdadm/mdadm.conf
/etc/init.d/mdadm restart

ln -s /dev/md0 /dev/md/0
ln -s /dev/md1 /dev/md/1

echo "export IP=$SERVER_IP::$SERVER_GATEWAY:$SERVER_NETMASK:debsrv:eth0:off
" > /etc/initramfs-tools/conf.d/network_config

chmod +x /etc/initramfs-tools/hooks/mount_cryptroot
chmod +x /etc/initramfs-tools/scripts/local-top/cryptraid

echo "# <target name> <source device> <key file> <options>
raid UUID=$UUID_MD1 none luks
" > /etc/crypttab
echo "dm-crypt" >> /etc/modules

update-initramfs -u -k all

apt-get install -y grub2

sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="cryptdevice=\/dev\/md1:raid"/g' /etc/default/grub
sed -i 's/#GRUB_DISABLE_LINUX_UUID/GRUB_DISABLE_LINUX_UUID/g' /etc/default/grub
update-grub

update-initramfs -u -k all

passwd
EOF

chmod +x /mnt/debian/setup.sh

LANG=C chroot /mnt/debian /setup.sh

