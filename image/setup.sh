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

# Already stripped by the stage:payload task, on the build host. Deliberately not stripped here: doing
# it in the chroot would mean installing binutils INTO the image to run `strip` once, which is exactly
# the kind of build tool this appliance exists to not have.
install -m 0755 -o root -g root /mnt/bao /usr/sbin/bao

# Stripping is the one place the image stops being byte-identical to what upstream published, so the
# link is recorded rather than lost: this file names the checksum mise verified the download against and
# the checksum of what actually shipped.
install -m 0644 -o root -g root /mnt/provenance /etc/openbao-binary-provenance

# Deliberately NOT setcap'd, and now not granted any capability at all. This carried CAP_IPC_LOCK for
# mlock until a live Droplet showed OpenBao 2.x has dropped mlock support; see /etc/init.d/openbao.
# Leaving the binary untouched also keeps it byte-identical to upstream's apart from the strip recorded
# above.

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

echo "==> networking"
# Written HERE rather than shipped in the overlay, because alpine-make-vm-image generates this file
# itself after the skel rsync and its version wins. Discovered by an assertion failing on a built image.
#
# There are deliberately NO post-up hook lines. The generated file ends with
# `post-up /etc/network/if-post-up.d/*`; that directory does not exist, the glob never expands, and sh
# fails on the literal path -- so ifup reports failure for an interface whose DHCP lease it had just
# obtained. And because options after an `iface` stanza belong to that stanza, those trailing lines bind
# to the LAST one, eth1: net.eth1 stayed permanently failed while eth1 held an address configured by
# tiny-cloud instead. A working interface for the wrong reason, which is the failure mode this whole
# image has taught us to distrust.
cat > /etc/network/interfaces <<-'INTERFACES'
	auto lo
	iface lo inet loopback

	# DigitalOcean serves DHCP on both interfaces for custom images. Its DHCP runs on port 67, so an
	# outbound UDP rule for it is required if a firewall is ever applied to this Droplet.
	auto eth0
	iface eth0 inet dhcp

	# The VPC interface, and the one this appliance exists to serve on: OpenBao advertises its private
	# address, the Agent sidecars dial it, and the firewall admits 8200 from nowhere else.
	auto eth1
	iface eth1 inet dhcp
INTERFACES
grep -q 'if-post-up.d' /etc/network/interfaces && {
	echo "FATAL: the generated ifup hooks survived; net.eth1 would fail" >&2
	exit 1
}
# The per-interface services Alpine expects, and which alpine-make-vm-image does not create. Without
# these, `networking` is in no runlevel, nothing provides `net`, and every service that needs it never
# runs -- see the comment in /etc/network/interfaces for the full failure.
#
# This is what the working Alpine-on-DigitalOcean images do, and the shape is Alpine's own convention:
# net.lo in boot, one net.<iface> per interface in default, each a symlink to the networking script.
for interface in lo eth0 eth1; do
	ln -sf networking "/etc/init.d/net.$interface"
done
# `net` must be satisfied by ANY interface coming up, not all of them. OpenRC defaults to strict
# dependencies, under which one failing provider leaves the whole virtual unsatisfied -- so a Droplet
# created without VPC networking, where eth1 does not exist, would leave `net` unprovided and take
# cloud-ssh-keys and tiny-cloud-main down with it. That is the exact failure this image already shipped
# once, reached by a different route.
#
# Measured in QEMU, which has a single NIC: net.eth1 fails with "Cannot find device eth1" and net.eth0
# comes up fine. With this set, that is a working boot rather than an unreachable node.
sed -i 's|^#\?rc_depend_strict=.*|rc_depend_strict="NO"|' /etc/rc.conf
grep -q '^rc_depend_strict="NO"' /etc/rc.conf || echo 'rc_depend_strict="NO"' >> /etc/rc.conf

rc-update add net.lo boot
rc-update add net.eth0 default
rc-update add net.eth1 default

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
rc-update add chronyd default   # client-only; see /etc/chrony/conf.d/10-appliance.conf
# Before sshd, and not trusting tiny-cloud to have done it. See the service for why.
rc-update add cloud-ssh-keys default
rc-update add sshd default
rc-update add openbao-pod-routes default

# OpenBao IS enabled, unlike the systemd unit in stack's cloud-init, which is installed disabled so the
# operator's TLS step cannot be skipped by a reboot. That reasoning is inverted here on purpose: the
# init script refuses to start without TLS material, so the gate is kept, while a node that reboots
# after TLS is in place comes back on its own. A secret store that stays down after an unattended
# reboot is a worse failure than one that starts too eagerly, and with one node and no quorum that
# reboot is the whole availability story.
rc-update add openbao default

echo "==> cloud user"
# WITHOUT THIS THE NODE IS UNREACHABLE, and nothing says so.
#
# tiny-cloud ships CLOUD_USER commented out (`#CLOUD_USER=alpine`), so it is empty. init__set_ssh_keys
# then runs `getent passwd ""`, fails to find the user, logs "failed to find user" to the system log and
# returns -- without writing /root/.ssh/authorized_keys. The Droplet boots, configures its network and
# answers on port 22 with sshd running, and refuses every key. Alpine's own cloud images set this and
# create an `alpine` user; an image built by alpine-make-vm-image has neither.
#
# root, because that is the account DigitalOcean injects keys for and the only one sshd here admits --
# see AllowUsers in 10-appliance.conf. `create_default_user` finds root already exists and skips.
#
# Found on a real Droplet. QEMU could not have found it: with no metadata service there are no keys to
# install either way, so the step looks identical whether it works or not.
sed -i 's|^#\?CLOUD_USER=.*|CLOUD_USER=root|' /etc/tiny-cloud.conf
grep -q '^CLOUD_USER=root' /etc/tiny-cloud.conf || echo 'CLOUD_USER=root' >> /etc/tiny-cloud.conf
grep -q '^CLOUD_USER=root' /etc/tiny-cloud.conf || {
	echo "FATAL: CLOUD_USER is not set; the node would boot unreachable" >&2
	exit 1
}

echo "==> hardening"
# NOT `passwd -l root`, and the difference is the whole reachability of this image.
#
# `passwd -l` prefixes the shadow hash with `!`, which marks the account LOCKED. Alpine builds sshd
# without PAM, and OpenSSH refuses a locked account outright -- before it ever looks at authorized_keys.
# So every Droplet from this image had the operator's key installed correctly and was still refused with
# "Permission denied (publickey)". It cost five rounds of chasing tiny-cloud, CLOUD_USER, metadata
# routing and OpenRC ordering, all of which were real bugs and none of which were this one.
#
# Setting the field to `*` gives the same property that was actually wanted -- no password can ever match
# -- without setting the lock flag. Measured on a live Droplet: with `!` key auth is refused, with `*` it
# succeeds, everything else identical.
sed -i 's|^root:[^:]*:|root:*:|' /etc/shadow
grep -q '^root:\*:' /etc/shadow || {
	echo "FATAL: root's password field is not '*'; the node would be unreachable" >&2
	exit 1
}

# A DEBUG BUILD, and never a released one.
#
# When the stage directory carries a debug-password file, this unlocks root and turns on password
# authentication so the DigitalOcean console and plain ssh both work. It exists because this image can
# boot unreachable, and a node nobody can log into cannot be diagnosed -- which has now cost five
# rounds of inference from outside the machine.
#
# scripts/verify-image asserts the opposite of everything here ("root password locked", "password auth
# disabled"), so a debug image cannot pass verification and therefore cannot be released by the
# workflow. The marker file is a second, human-readable tripwire.
if [ -f /mnt/debug-password ]; then
	echo "    *** DEBUG BUILD: password authentication enabled ***"
	printf 'root:%s' "$(cat /mnt/debug-password)" | chpasswd
	# 00-, not 99-: sshd takes the FIRST obtained value for each keyword, and the include glob is read in
	# lexical order, so 10-appliance.conf's `PasswordAuthentication no` wins against anything sorting
	# after it. A 99- prefix produced an sshd that ignored every line in this file.
	cat > /etc/ssh/sshd_config.d/00-debug.conf <<-'DEBUG'
	# DEBUG BUILD ONLY. Must sort before 10-appliance.conf to take effect.
	PasswordAuthentication yes
	AuthenticationMethods any
	PermitRootLogin yes
	DEBUG
	cat > /etc/APPLIANCE-DEBUG <<-'MARKER'
	This image was built with debug password authentication enabled.
	It is a diagnostic artifact and must never be deployed.
	MARKER
fi

# No swap is configured and none should be. This is not a backstop but THE control: OpenBao 2.x has
# dropped mlock, and upstream's replacement advice is exactly "disable or encrypt swap instead", so the
# absence of swap is the only thing keeping decrypted secret material out of a disk-backed page.
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

# Python's dependency closure, orphaned by the line above and left behind because that is an `rm` rather
# than an `apk del` -- apk would refuse, since `apparmor` declares python3 as a hard dependency.
#
# Measured after the fact: nothing in the image references libsqlite3 or libmpdec at all. libstdc++ is
# NOT in this list and must not be: apparmor_parser links it, and removing it takes AppArmor with it.
rm -f /usr/lib/libsqlite3.so* /usr/lib/libmpdec*
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

# Kernel modules for hardware this machine does not have and filesystems it will never mount.
#
# This is attack surface before it is size. A filesystem or network-protocol parser in the kernel is a
# classic exploit target, and a module that is not on disk cannot be autoloaded by anything that
# provokes the kernel into trying -- `mount -t squashfs` on a crafted image, say. This appliance mounts
# exactly two filesystems, ext4 for its root and ext4 for the Raft volume, and speaks TCP over virtio.
#
# Kept deliberately: virtio-rng, because this host generates keys and wants entropy; nvme, because
# DigitalOcean's storage presentation is not guaranteed to stay virtio-blk; and the whole crypto and
# ipv4/ipv6 trees.
release="$(ls /lib/modules | head -1)"
modules="/lib/modules/$release/kernel"
for dead in sound drivers/gpu drivers/usb drivers/md drivers/hid drivers/input \
            drivers/target drivers/message drivers/xen drivers/bluetooth \
            net/netfilter net/sched net/sunrpc net/ceph net/sctp net/bridge net/9p; do
	rm -rf "${modules:?}/$dead"
done

# Every filesystem except the one this appliance uses. ext4 needs jbd2 and mbcache beside it.
find "$modules/fs" -mindepth 1 -maxdepth 1 \
	! -name ext4 ! -name jbd2 ! -name 'mbcache*' -exec rm -rf {} + 2>/dev/null || true

# modules.dep still describes what was deleted, and a stale dependency file makes modprobe fail in a way
# that reads as a missing driver rather than a stale index.
depmod -a "$release"

# The kernel symbol map, which exists to decode an oops on a machine with a debugger attached. This one
# sets ptrace_scope=3 and has no debugger, and the file is 6.1 MiB.
rm -f /boot/System.map-*

# syslinux's installable payload, 3.5 MiB. extlinux has already been installed into /boot by this point,
# so what is left is the source material for an installation that has happened.
rm -rf /usr/share/syslinux

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

# Zero the free space, which does two things and the second matters more than the first.
#
# Size: qcow2 allocates a cluster the moment it is written and never releases it when the guest deletes
# the file, so an image that grew to 300 MiB and then had 80 MiB removed is still a 300 MiB file. Only
# zero clusters can be dropped, and only by a rewrite -- see the build:compact task.
#
# Hygiene: everything deleted above is still readable in the freed blocks -- the Python runtime, the
# pruned kernel modules, the apk cache and its index. This image is published, so those remnants would
# be published with it. Zeroing removes them rather than merely unlinking them.
dd if=/dev/zero of=/ZEROFILL bs=1M 2>/dev/null || true
rm -f /ZEROFILL
sync

echo "==> setup complete"
