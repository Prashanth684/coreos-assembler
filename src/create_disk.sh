#!/bin/sh
# This script is run in supermin to create a Fedora CoreOS style
# disk image, very much in the spirit of the original
# Container Linux (orig CoreOS) disk layout, although adapted
# for OSTree, and using XFS for /, among other things.
# Some more background in https://github.com/coreos/fedora-coreos-tracker/issues/18
# The layout is intentionally not very configurable at this time,
# although see also https://github.com/coreos/coreos-assembler/pull/298
# For people building "derived"/custom FCOS-like systems, feel free to file
# an issue and we can discuss configuration needs.
set -euo pipefail

usage() {
    cat <<EOC
${0} create a supermin virtual machinge to create a
Fedora CoreOS style disk image from an OS Tree.

Options:
    --disk: disk device to use
    --buildid: buildid
    --imgid: imageid
    --grub-script: grub script to install
    --help: show this helper
    --kargs: kernel CLI args
    --osname: the OS name to use, e.g. fedora
    --ostree-ref: the OSTRee reference to install
    --ostree-remote: the ostree remote
    --ostree-repo: location of the ostree repo
    --save-var-subdirs: "yes" to workaround selabel issue for RHCOS

You probably don't want to run this script by hand. This script is
run as part of 'coreos-assembler build'.
EOC
}

extrakargs=""
while [ $# -gt 0 ];
do
    flag="${1}"; shift;
    case "${flag}" in
        --disk)             disk="${1}"; shift;;
        --buildid)          buildid="${1}"; shift;;
        --imgid)            imgid="${1}"; shift;;
        --grub-script)      grub_script="${1}"; shift;;
        --help)             usage; exit;;
        --kargs)            extrakargs="${extrakargs} ${1}"; shift;;
        --osname)           os_name="${1}"; shift;;
        --ostree-ref)       ref="${1}"; shift;;
        --ostree-remote)    remote_name="${1}"; shift;;
        --ostree-repo)      ostree="${1}"; shift;;
        --save-var-subdirs) save_var_subdirs="${1}"; shift;;
         *) echo "${flag}=${1} is not understood."; usage; exit 10;;
         --) break;
     esac;
done

export PATH=$PATH:/sbin:/usr/sbin
arch="$(uname -m)"
disk="${disk:?--disk must be defined}"
buildid="${buildid:?--buildid must be defined}"
imgid="${imgid:?--imgid must be defined}"
ostree="${ostree:?--ostree-repo must be defined}"
ref="${ref:?--ostree-ref must be defined}"
remote_name="${remote_name:?--ostree-remote must be defined}"
grub_script="${grub_script:?--grub-script must be defined}"
os_name="${os_name:?--os_name must be defined}"
save_var_subdirs="${save_var_subdirs:?--save_var_subdirs must be defined}"

set -x

# Partition and create fs's. The 0...4...a...1 uuid is a sentinal used by coreos-gpt-setup
# in ignition-dracut. It signals that the disk needs to have it's uuid randomized and the
# backup header moved to the end of the disk.
sgdisk -Z $disk \
	-U 00000000-0000-4000-a000-000000000001 \
	-n 1:0:+384M -c 1:boot \
	-n 2:0:+127M -c 2:EFI-SYSTEM -t 2:C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
	-n 3:0:+1M   -c 3:BIOS-BOOT  -t 3:21686148-6449-6E6F-744E-656564454649 \
	-n 4:0:0     -c 4:root       -t 4:4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
sgdisk -p "$disk"

udevadm trigger
udevadm settle

mkfs.ext4 "${disk}1" -L boot
mkfs.fat "${disk}2" -n EFI-SYSTEM
# partition 3 has no FS, its for bios grub
mkfs.xfs "${disk}4"  -L root -m reflink=1

# mount the partitions
rm -rf rootfs
mkdir rootfs
mount "${disk}4" rootfs
chcon $(matchpathcon -n /) rootfs
mkdir rootfs/boot
chcon $(matchpathcon -n /boot) rootfs/boot
mount "${disk}1" rootfs/boot
chcon $(matchpathcon -n /boot) rootfs/boot
mkdir rootfs/boot/efi
# FAT doesn't support SELinux labeling, it uses "genfscon", so we
# don't need to give it a label manually.
mount "${disk}2" rootfs/boot/efi

# Initialize the ostree setup; TODO replace this with
# https://github.com/ostreedev/ostree/pull/1894
# `ostree admin init-fs --modern`
mkdir -p rootfs/ostree
chcon $(matchpathcon -n /ostree) rootfs/ostree
mkdir -p rootfs/ostree/{repo,deploy}
ostree --repo=rootfs/ostree/repo init --mode=bare
remote_arg=
deploy_ref="${ref}"
if [ "${remote_name}" != NONE ]; then
    remote_arg="--remote=${remote_name}"
    deploy_ref="${remote_name}:${ref}"
fi
ostree pull-local "$ostree" "$ref" --repo rootfs/ostree/repo $remote_arg
ostree admin os-init "$os_name" --sysroot rootfs
allkargs='root=/dev/disk/by-label/root rootflags=defaults,prjquota rw $ignition_firstboot'
allkargs="$allkargs $extrakargs"
kargsargs=""
for karg in $allkargs
do
	kargsargs+="--karg-append=$karg "
done
ostree admin deploy "${deploy_ref}" --sysroot rootfs --os "$os_name" $kargsargs

# This will allow us to track the version that an install
# originally used; if we later need to understand something
# like "exactly what mkfs.xfs version was used" we can do
# that via looking at the upstream build and finding the
# build logs for it, getting the coreos-assembler version,
# and getting the `rpm -qa` from that.
#
# build:         The coreos-assembler build ID; today we support
#                having the same ostree commit in different image builds.
# ref:           The ostree ref used; useful for cross-checking.
# ostree-commit: Similar to `ref`; one can derive this from looking
#                at the coreos-assembler builds, but it's very
#                convenient to have here as a strong cross-reference.
# imgid:         The full image name, the same as will end up in the
#                `images` dict in `meta.json`.
ostree_commit=$(ostree --repo="${ostree}" rev-parse "${ref}")
cat > rootfs/.coreos-aleph-version.json << EOF
{
	"build": "${buildid}",
	"ref": "${ref}",
	"ostree-commit": "${ostree_commit}",
	"imgid": "${imgid}"
}
EOF

# See the equivalent code in gf-anaconda-cleanup
# /var hack: we'd like to remove all of /var, but SELinux issues prevent that.
# see https://github.com/coreos/ignition-dracut/pull/79#issuecomment-488446949
if [ "${save_var_subdirs}" != NONE ]; then
	vardir=rootfs/ostree/deploy/${os_name}/var
	mkdir -p ${vardir}/{home,log/journal,lib/systemd}
	# And /home is the only one that doesn't have a filename transition today
	chcon -h $(matchpathcon -n /home) ${vardir}/home
fi

if [ "$arch" == "x86_64" ]; then
	# install bios grub
	grub2-install \
		--target i386-pc \
		--boot-directory rootfs/boot \
		$disk
	ext="X64"
elif [ "$arch" == "aarch64" ]; then
	mkdir -p rootfs/boot/grub2
	ext="AA64"
fi

# we use pure BLS, so don't need grub2-mkconfig
ostree config --repo rootfs/ostree/repo set sysroot.bootloader none

if [ "$arch" != "s390x" ]; then
	# install uefi grub
	mkdir -p rootfs/boot/efi/EFI/{BOOT,fedora}
	cp "/boot/efi/EFI/BOOT/BOOT${ext}.EFI" "rootfs/boot/efi/EFI/BOOT/BOOT${ext}.EFI"
	cp "/boot/efi/EFI/fedora/grub${ext,,}.efi" "rootfs/boot/efi/EFI/BOOT/grub${ext,,}.efi"
	cat > rootfs/boot/efi/EFI/fedora/grub.cfg << 'EOF'
search --label boot --set prefix
set prefix=($prefix)/grub2
normal
EOF

	# copy the grub config and any other files we might need
	cp $grub_script rootfs/boot/grub2/grub.cfg
else
	# current zipl expects 'title' to be first line, and no blank lines in BLS file
	# see https://github.com/ibm-s390-tools/s390-tools/issues/64
	blsfile=$(find rootfs/boot/loader/entries/*.conf)
	tmpfile=$(mktemp)
	for f in title version linux initrd; do
		echo $(grep $f $blsfile) >> $tmpfile
	done
	# we force firstboot in building base image on s390x, ignition-dracut hook will remove
	# this and update zipl for second boot
	# this is only a temporary solution until we are able to do firstboot check at bootloader
	# stage on s390x, either through zipl->grub2-emu or zipl standalone.
	# See https://github.com/coreos/ignition-dracut/issues/84
	options="$(grep options $blsfile | cut -d' ' -f2-) ignition.firstboot rd.neednet=1 ip=dhcp"
	echo "options $options" >> $tmpfile
	cat $tmpfile > $blsfile

	# ideally we want to invoke zipl with bls and zipl.conf but we might need
	# to chroot to rootfs/ to do so. We would also do that when FCOS boot on its own.
	# without chroot we can use --target option in zipl but it requires kernel + initramfs
	# pair instead
	echo $options > $tmpfile
	zipl --verbose \
		--target rootfs/boot \
		--image rootfs/boot/"$(grep linux $blsfile | cut -d' ' -f2)" \
		--ramdisk rootfs/boot/"$(grep initrd $blsfile | cut -d' ' -f2)" \
		--parmfile $tmpfile
fi

touch rootfs/boot/ignition.firstboot

# Finally, add the immutable bit to the physical root; we don't
# expect people to be creating anything there.  A use case for
# OSTree in general is to support installing *inside* the existing
# root of a deployed OS, so OSTree doesn't do this by default, but
# we have no reason not to enable it here.  Administrators should
# generally expect that state data is in /etc and /var; if anything
# else is in /sysroot it's probably by accident.
chattr +i rootfs

umount -R rootfs
