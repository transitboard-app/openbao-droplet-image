#!/bin/sh
# Runs inside the image's chroot, after packages are installed and the overlay is in place, and before
# the image is unmounted. Its directory is bind-mounted at /mnt.
set -eu

BAO_UID=65532
BAO_GID=65532

echo "==> installing OpenBao"
# uid 65532 is not arbitrary: it is what upstream's distroless image runs as, and therefore what owns
# every file on the Raft volumes of the Droplets this image replaces. Changing it would make an
# existing volume unreadable to the new node, which is the one failure a secret store cannot absorb.
addgroup -g "$BAO_GID" -S openbao
adduser -u "$BAO_UID" -G openbao -S -H -D -s /sbin/nologin openbao

install -m 0755 -o root -g root /mnt/bao /usr/sbin/bao

# Deliberately NOT setcap'd. CAP_IPC_LOCK is granted at start time as an *ambient* capability by
# supervise-daemon (see /etc/init.d/openbao), which has two advantages over a file capability: the
# binary stays byte-identical to the one upstream published and pinned by digest, and ambient
# capabilities survive alongside no_new_privs, which file capabilities do not -- setting both would
# have silently produced a process with neither.

install -d -o root -g root -m 0755 /etc/openbao
install -d -o "$BAO_UID" -g "$BAO_GID" -m 0700 /etc/openbao/tls
install -d -o "$BAO_UID" -g "$BAO_GID" -m 0700 /var/lib/openbao
install -d -o "$BAO_UID" -g "$BAO_GID" -m 0700 /var/log/openbao

echo "==> kernel command line"
# THE line without which the AppArmor profile in this image is decorative.
#
# linux-virt sets CONFIG_SECURITY_APPARMOR=y but ships
# CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity" -- apparmor is compiled in and absent
# from the active stack. Booting without this, apparmor_parser still loads the profile without error,
# aa-status reports nothing, and OpenBao runs unconfined. It fails open and it fails quietly, which is
# why scripts/verify-image asserts the parameter is present and the boot self-check asserts the process
# is actually confined.
#
# The rest are ordinary hardening. init_on_alloc/init_on_free earn their keep on this host in
# particular: they zero pages on allocation and free, which is exactly what you want on a machine whose
# heap holds unsealed key material.
#
# Not enabled yet, deliberately, because each can prevent boot and this image is not yet proven to boot
# at all: lockdown=integrity, mitigations=auto,nosmt. Add them one at a time, with a boot test each.
lsm_list="landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor"
hardening="slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none debugfs=off"

# APPENDED to what is already there, not written over it. alpine-make-vm-image's --serial-console puts
# `console=ttyS0,115200` in these options, and an earlier version of this line replaced the whole value
# and silently dropped it -- which costs the DigitalOcean recovery console and every panic message a
# failed boot would otherwise print. The assertion below is what caught it.
existing="$(sed -n 's/^default_kernel_opts="\(.*\)"$/\1/p' /etc/update-extlinux.conf)"
sed -i "s|^default_kernel_opts=.*|default_kernel_opts=\"${existing} lsm=${lsm_list} apparmor=1 ${hardening}\"|" \
	/etc/update-extlinux.conf

# alpine-make-vm-image configures extlinux BEFORE this script runs, so the edit above is not picked up
# unless update-extlinux is run again here. Skipping this produces an image that boots perfectly and is
# entirely unconfined.
update-extlinux --warn-only 2>&1 | grep -Fv 'cannot open device /dev' || true
grep -q "apparmor=1" /boot/extlinux.conf || {
	echo "FATAL: apparmor=1 did not reach /boot/extlinux.conf" >&2
	exit 1
}
grep -q "console=ttyS0" /boot/extlinux.conf || {
	echo "FATAL: console=ttyS0 was lost from the kernel command line" >&2
	echo "Without it a failed boot prints nothing to DigitalOcean's recovery console." >&2
	exit 1
}
echo "    $(grep -m1 'APPEND' /boot/extlinux.conf | tr -s ' ')"

echo "==> services"
# boot: before networking, and before anything that needs a confined process or a grown filesystem.
rc-update add apparmor boot
# tiny-cloud-boot grows the root partition and filesystem to fill the Droplet's disk. Measured on a
# 5 GiB disk built from a 1 GiB image: partition and filesystem both ended at 5 GiB. A hand-written
# expand-root service shipped here briefly and was removed once tiny-cloud was shown to do the work --
# two things racing to repartition the disk holding the secret store is not redundancy worth having.
rc-update add tiny-cloud-boot boot

# default: everything that needs the network up.
rc-update add tiny-cloud-early default
rc-update add tiny-cloud-main default
rc-update add tiny-cloud-final default
rc-update add chronyd default
rc-update add sshd default
rc-update add openbao-pod-routes default

# OpenBao IS enabled, unlike the systemd unit in stack's cloud-init, which is installed disabled so the
# operator's TLS step cannot be skipped by a reboot. That reasoning is inverted here on purpose: the
# init script refuses to start without TLS material, so the gate is kept, while a node that reboots
# after TLS is in place comes back on its own. A secret store that stays down after an unattended
# reboot is a worse failure than one that starts too eagerly, and with one node and no quorum that
# reboot is the whole availability story.
rc-update add openbao default

echo "==> hardening"
passwd -l root

# No swap is configured and none should be. CAP_IPC_LOCK plus mlock is the primary control (OpenBao's
# `disable_mlock` is deliberately absent from the shipped config); the absence of swap is the backstop
# for anything mlock does not cover.
sed -i '/\bswap\b/d' /etc/fstab 2>/dev/null || true

# Alpine's default motd advertises a general-purpose system. This is not one.
cat > /etc/motd <<'MOTD'

  Transitboard OpenBao appliance.

  Single purpose: OpenBao, confined by AppArmor, running as uid 65532.
  There is no package manager and no reason to install anything here.

  status    rc-service openbao status
  confined  cat /sys/kernel/security/apparmor/profiles
  selfcheck openbao-selfcheck

MOTD

echo "==> recording the package set"
# The recipe pins a branch, not versions, so a rebuild picks up security updates and two builds of the
# same recipe are not byte-identical. This file is what makes them distinguishable after the fact, and
# is what an incident response reads to find out what was actually on the node.
# Read out of apk's own database rather than by running `apk list --installed`.
#
# That command produced nothing here and said so only on stderr, which an earlier version of this line
# discarded -- leaving an image whose sole record of its contents was an empty file, and 30 passing
# offline checks. The cause is that on a non-Alpine build host the packages are installed by static
# apk-tools 2.14.10 while the chroot's own apk is 3.x, and `list` wants an index it cannot reach.
#
# The database is version-independent and always present: P: is a package name, V: its version.
awk '/^P:/{p=substr($0,3)} /^V:/{print p "-" substr($0,3)}' /lib/apk/db/installed | sort \
	> /etc/openbao-appliance-packages
test -s /etc/openbao-appliance-packages || {
	echo "FATAL: the package record is empty; nothing would document this image's contents" >&2
	exit 1
}
wc -l < /etc/openbao-appliance-packages | xargs echo "    packages installed:"

echo "==> removing what the appliance does not run"
# Each of these is measured by scripts/verify-image rather than assumed, because every one of them is
# the kind of thing that quietly reappears when a package is added.

# Python, pulled in by `apparmor` as a hard dependency for its aa-* helper scripts. The appliance uses
# none of them: /etc/init.d/apparmor is a plain OpenRC shell script, and apparmor_parser is a C binary
# that runs fine without an interpreter (verified before this line was written). Leaving it would put a
# 60 MiB scripting runtime on the host holding every production credential, which is the exact thing
# choosing tiny-cloud over cloud-init avoided.
rm -rf /usr/bin/python3* /usr/lib/python3* /usr/lib/libpython3* 2>/dev/null || true
# /usr/bin/python is a symlink to python3 and is left dangling by the line above. Harmless in itself,
# but verify-image rejects dangling symlinks wholesale -- the check exists because deleting a binary
# that other names point at is exactly how `mount` went missing once.
rm -f /usr/bin/python
/sbin/apparmor_parser --version >/dev/null 2>&1 || {
	echo "FATAL: apparmor_parser stopped working after removing Python" >&2
	exit 1
}

# busybox's setuid helper. Stripped of its setuid bit, NOT deleted -- and the difference is the whole
# boot.
#
# Alpine symlinks /bin/mount, /bin/umount, /bin/su and friends at /bin/bbsuid rather than at busybox,
# because those applets need setuid for non-root users. Deleting it therefore deletes `mount`, and an
# earlier version of this line did exactly that: the image booted, mounted its root read-only, and then
# OpenRC failed at `Mounting /run ... mount: not found` and gave up before starting a single service.
# Every offline check still passed, because nothing about a dangling symlink is visible in the
# filesystem's contents.
#
# Removing the mode bits keeps the binary working for root, which is the only user here, while leaving
# nothing setuid on the image for a non-root process to target.
chmod u-s,g-s /bin/bbsuid

rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true

# apk itself, last, because everything above needed it.
#
# This is what makes the appliance immutable rather than merely minimal: a node cannot be patched in
# place, and a security update means building a new image and replacing the Droplet. That is the
# intended operating model, and it is the reason /etc/openbao-appliance-packages is written above --
# with no package manager, that file is the only record of what is installed.
#
# /lib/apk/db is deliberately kept: it is readable without apk and is what an incident response needs.
rm -f /sbin/apk

# The package record above was written while apk still worked, so it lists what apk installed rather
# than what survives on the running node. The three removals are force-deletions rather than `apk del`
# (each is a hard dependency of something the appliance does need), so apk's database still believes
# they are present. Recording the difference is what keeps the file honest for an incident response.
cat >> /etc/openbao-appliance-packages <<'REMOVED'

# Force-removed after installation; apk's database above still lists them as installed:
#   python3, python3-pyc, pyc  -- a hard dependency of `apparmor`, used only by its aa-* helper scripts
#   busybox-suid (/bin/bbsuid) -- the setuid helper; nothing here runs as a non-root human
#   apk-tools (/sbin/apk)      -- removed last; this image is replaced, never patched in place
REMOVED

echo "==> setup complete"
