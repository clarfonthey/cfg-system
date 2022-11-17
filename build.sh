#!/bin/bash
shopt -s nullglob

ROOT_MNT="$PWD/root.mnt"
ROOT_IMG="$PWD/root.img"
DATA_IMG="$PWD/data.img"
umount_special()
{
    test -d "$ROOT_MNT" &&
    for d in "$ROOT_MNT"/{dev,proc,sys,run,tmp}; do
        while mountpoint "$d" >/dev/null 2>/dev/null; do
            echo "waiting to unmount $d..." >&2
            sudo umount -qR "$d"
            sleep 1
        done
    done
}
cleanup()
{
    cd /

    echo 'deleting podman container...' >&2
    if test -n "$CONTAINER"; then
        sudo podman rm "$CONTAINER"
    fi

    echo 'unmounting non-ZFS partitions...' >&2
    sudo umount -qR "$ROOT_MNT/"*
    umount_special

    echo 'unmounting datasets...' >&2
    for dataset in $(mount | sed -ne 's/^\(cld_[^ ]*\).*/\1/p' | sort -u); do
        sudo zfs unmount $dataset
    done

    echo 'removing zpools...' >&2
    sudo zpool export cld_r
    sudo zpool export cld_d

    echo 'removing mount directories...' >&2
    sudo rm -rf "$ROOT_MNT"

    echo 'removing mappers...' >&2
    sudo kpartx -d "$ROOT_IMG"
    sudo kpartx -d "$DATA_IMG"

    echo 'flushing data...' >&2
    sync

    cd "$(dirname "$ROOT_MNT")"
}
run_root()
{
    sudo arch-chroot "$ROOT_MNT" "$@"
    umount_special
}
bye()
{
    exit
}
trap cleanup EXIT
trap bye INT
cleanup
sudo rm -f "$ROOT_IMG" "$DATA_IMG"

zpool_features()
{
    sed -e "s/^/$1 /g" "disk/$2/zpool" | tr '\n' ' ' | sed -e 's/ *$//'
}
zfs_features()
{
    sed -e "s/^/$1 /g" "disk/$2/zfs" | tr '\n' ' ' | sed -e 's/ *$//'
}

echo 'synchronising packages...' >&2
sudo pacman -Syuw $(cat pkgs) --needed --noconfirm || exit 1

deptree=""
for d in $(cat pkgs); do
    deptree="$deptree $(pactree -l $d 2>/dev/null)"
done

echo 'building disk images...' >&2
ROOT_SIZE=10G
DATA_SIZE=10G
truncate -s "$ROOT_SIZE" "$ROOT_IMG"
truncate -s "$DATA_SIZE" "$DATA_IMG"

echo 'partitioning disk images...' >&2
sfdisk -q "$ROOT_IMG" < disk/root/sfdisk || exit 1
sfdisk -q "$DATA_IMG" < disk/data/sfdisk || exit 1

echo 'mapping disk images...' >&2
ROOT_DISK="$(sudo kpartx -av "$ROOT_IMG" | sed -e 's/add map \(loop[0-9][0-9]*\).*/\1/' | sort -u)"
DATA_DISK="$(sudo kpartx -av "$DATA_IMG" | sed -e 's/add map \(loop[0-9][0-9]*\).*/\1/' | sort -u)"
GRUB_MAPPER="$(realpath "/dev/mapper/${ROOT_DISK}p1")"
BOOT_MAPPER="$(realpath "/dev/mapper/${ROOT_DISK}p2")"
ROOT_MAPPER="$(realpath "/dev/mapper/${ROOT_DISK}p3")"
ROOT_DISK="$(realpath "/dev/${ROOT_DISK}")"
DATA_MAPPER="$(realpath "/dev/mapper/${DATA_DISK}p1")"
DATA_DISK="$(realpath "/dev/${DATA_DISK}")"

ROOT_UUID="$(sudo lsblk -no 'PARTUUID' "$ROOT_MAPPER")"
DATA_UUID="$(sudo lsblk -no 'PARTUUID' "$DATA_MAPPER")"

if test ! -e "$BOOT_MAPPER" -o ! -e "$ROOT_MAPPER" -o ! -e "$DATA_MAPPER"; then
    echo $BOOT_MAPPER $ROOT_MAPPER $DATA_MAPPER
    echo "failed to mount device mappers" >&2
    exit 1
fi

echo 'formatting boot partition...' >&2
sudo mkfs.fat -F 32 -n BOOT "$BOOT_MAPPER" || exit 1

echo 'creating root zpool...' >&2
mkdir -p "$ROOT_MNT"
sudo zpool create -d -f -m none -R "$ROOT_MNT" -t cld_r $(zpool_features -o root) $(zfs_features -O root) -o cachefile=none r "/dev/disk/by-partuuid/$ROOT_UUID" || exit 1

echo 'creating data zpool...' >&2
sudo zpool create -d -f -m none -R "$ROOT_MNT" -t cld_d $(zpool_features -o data) $(zfs_features -O data) -o cachefile=none d "/dev/disk/by-partuuid/$DATA_UUID" || exit 1

echo 'creating root datasets...' >&2
ROOT_DATASETS="$(find disk/root/*/ -name zfs | sed -e 's|/zfs$||g;s|^disk/root/||g' | sort -u)"
for dataset in $ROOT_DATASETS; do
    sudo zfs create "cld_r/$dataset" $(zfs_features -o "root/$dataset")
    grep -qF 'canmount=noauto' "disk/root/$dataset/zfs" && sudo zfs mount "cld_r/$dataset"
done

echo 'mounting boot...' >&2
sudo mkdir -p "$ROOT_MNT/boot"
sudo mount "$BOOT_MAPPER" "$ROOT_MNT/boot"

echo 'creating data datasets...' >&2
DATA_DATASETS="$(find disk/data/*/ -name zfs | sed -e 's|/zfs$||g;s|^disk/data/||g' | sort -u)"
for dataset in $DATA_DATASETS; do
    sudo zfs create "cld_d/$dataset" $(zfs_features -o "data/$dataset")
done

echo 'creating podman container...' >&2
CONTAINER="$(sudo podman create "$IMAGE")"

echo 'extracting podman filesystem...' >&2
sudo podman export "$CONTAINER" | sudo tar xf /dev/stdin -C "$ROOT_MNT"

echo 'generating fstab...' >&2
BOOT_UUID="$(sudo lsblk -no 'PARTUUID' "$BOOT_MAPPER")"
echo "PARTUUID=$BOOT_UUID  /boot  vfat  rw,relatime,fmask=0022,dmask=0022  0  2" | sudo tee "$ROOT_MNT/etc/fstab" >/dev/null

echo 'installing GRUB...' >&2
echo "\
(hd0) $ROOT_DISK
(hd0,1) $GRUB_MAPPER
(hd0,2) $BOOT_MAPPER
(hd0,3) $ROOT_MAPPER
(hd1) $DATA_DISK
(hd1,1) $DATA_MAPPER" | sudo tee "$ROOT_MNT/device.map" >/dev/null
run_root bash -c "grub-install --grub-mkdevicemap=/device.map --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable --no-nvram $ROOT_DISK"
run_root bash -c "grub-install --grub-mkdevicemap=/device.map --target=i386-pc --boot-directory=/boot $ROOT_DISK"
run_root bash -c "ZPOOL_VDEV_NAME_PATH=1 grub-mkconfig -o /boot/grub/grub.cfg"
sudo rm -f "$ROOT_MNT/device.map"

echo "updating files podman can't update..." >&2
run_root bash -c "
echo cld.ltdk.xyz > /etc/hostname &&
update-addrs local &&
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
"

echo 'waiting for processes to exit...' >&2
sync
cd /
wait
