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

# What built this image: the commit of the recipe, the Alpine branch, the OpenBao version and the date.
# A qcow2 carries no metadata, so for an artifact other people download this file is the only way to ask
# an image where it came from. Written by the stage:manifest task; see mise.linux-x64.toml.
install -m 0644 -o root -g root /mnt/release /etc/openbao-appliance-release

# Deliberately NOT setcap'd, and now not granted any capability at all. This carried CAP_IPC_LOCK for
# mlock until a live Droplet showed OpenBao 2.x has dropped mlock support; see /etc/init.d/openbao.
# Leaving the binary untouched also keeps it byte-identical to upstream's apart from the strip recorded
# above.

install -d -o root -g root -m 0755 /etc/openbao
# Everything OpenBao reads is root-owned with group read -- NOT 65532:65532 0700 -- and the difference is
# every operator command on the node.
#
# An AppArmor profile attaches to a path, so `profile openbao /usr/sbin/bao` confines the CLI an operator
# runs by hand exactly as it confines the server -- and the profile grants no capability of any kind.
# With the directory owned by 65532 and mode 0700, root needed CAP_DAC_READ_SEARCH merely to traverse it
# and did not have it, so `bao status` failed to read its own CA:
#
#   failed to read environment: Error loading CA File: open /etc/openbao/tls/ca.crt: permission denied
#   apparmor="DENIED" operation="capable" comm="bao" capname="dac_read_search"
#
# That broke `bao status`, `operator init`, `operator unseal`, `kv` and the whole first-boot procedure in
# README.md, and the workaround it invites -- `-tls-skip-verify` -- turns off certificate verification on
# the host holding every production credential.
#
# Giving the directory to root and letting the openbao group read it fixes that with no profile change:
# the server reads its key through the group, root traverses as owner, and neither needs a capability.
#
# It is also the stronger arrangement independently. Under the old ownership the uid OpenBao runs as owned
# the directory holding its own private key, so an AppArmor failure open -- the failure mode this image is
# most careful about -- left the process able to rewrite its own TLS material. It no longer can, whatever
# AppArmor is doing. /etc/init.d/openbao applies the same ownership to the files themselves on every
# start, so an operator's `scp` cannot get it wrong.
#
# **No /etc/openbao/tls.** TLS material lives on the attached volume since 2026-08-11, at
# /var/lib/openbao/tls, so that a replacement Droplet reattaches it instead of an operator copying a key
# back. Leaving the old directory here would be worse than deleting it: an `scp` to the old path would
# succeed and the node would still refuse to start, naming a directory that looked correct.
# scripts/verify-image asserts its absence.
#
# The mountpoint, root-owned with group read rather than owned by the uid OpenBao runs as. That is what
# lets TLS live on this volume at all: the AppArmor profile attaches to /usr/sbin/bao and grants no
# capability, so a confined `bao` run by root cannot traverse a 0700 directory owned by 65532 -- which is
# the failure this ownership was chosen to avoid in the first place. /etc/init.d/openbao-volume creates
# the subdirectories after mounting, with Raft owning its own.
install -d -o root -g "$BAO_GID" -m 0750 /var/lib/openbao
install -d -o "$BAO_UID" -g "$BAO_GID" -m 0700 /var/log/openbao

# The configuration directory and the seal key directory, both root-owned with group read, for the same
# reason /etc/openbao/tls is: root owns them so a confined root can traverse them without a capability,
# and the openbao group reads them so the server can. The overlay has already put the fragments in
# place; this fixes the ownership the copy could not set.
#
# /etc/openbao/seal ships empty and usually stays that way. It exists so that an operator installing a
# static seal key has a directory with the right mode already waiting, rather than creating one by hand
# and getting it wrong once.
install -d -o root -g "$BAO_GID" -m 0750 /etc/openbao/config.d
install -d -o root -g "$BAO_GID" -m 0750 /etc/openbao/seal
for fragment in /etc/openbao/config.d/*.hcl; do
	chown root:"$BAO_GID" "$fragment"
	chmod 0640 "$fragment"
done

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
# module.sig_enforce=1 makes the kernel refuse an unsigned module. Boot-tested on its own:
# /sys/module/module/parameters/sig_enforce reads Y, Alpine's own signed modules load normally, and a
# tampered one is rejected with `insmod: ERROR: could not insert module: Key was rejected by service`.
# The kernel already sets CONFIG_MODULE_SIG_ALL=y and carries Alpine's key, so nothing else was needed.
# This is what turns the module removal below from a measure against autoloading into a measure against
# an attacker who already has root.
#
# lockdown=integrity closes the kernel-modification interfaces root would otherwise keep -- /dev/mem,
# kexec, unsigned modules, BPF writes to kernel memory. Boot-tested on its own:
# /sys/kernel/security/lockdown reads `none [integrity] confidentiality`, OpenBao unsealed and served a
# KV read under it, and openbao-selfcheck came back fully green. `lockdown` was already in the lsm= list;
# only the mode was missing.
#
# Still not enabled, and still for the stated reason -- it can prevent boot and has not been tested here:
# mitigations=auto,nosmt. Add it on its own, with a boot test.
#
# Worth knowing next to randomize_kstack_offset, and not fixable here: `bao` is a non-PIE ELF EXEC, so
# its own text is not subject to ASLR. That is upstream's build choice; the kernel options below do not
# reach it.
lsm_list="landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor"
hardening="slab_nomerge init_on_alloc=1 init_on_free=1 randomize_kstack_offset=on vsyscall=none debugfs=off"
hardening="$hardening lockdown=integrity module.sig_enforce=1"

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

# Start services in parallel. OpenRC defaults this off, so every service on this node waited for the one
# before it whether or not it depended on it.
#
# Measured on a steady-state reboot in the lab, three runs each: SSH answering at 52s becomes 42s and
# OpenBao's listener at 60s becomes 48s, both about 20% off. The absolute numbers are emulation and mean
# nothing; the ratio is the point, and it comes from the parts of the boot that were always independent
# -- DHCP on two interfaces, chronyd, crond and sshd have no reason to be serialised behind each other.
#
# This is only safe because the dependencies are declared rather than implied by order, which they now
# are: openbao needs net, localmount, metadata and openbao-volume; cloud-ssh-keys needs metadata and
# comes before sshd; openbao-volume comes before openbao. A service that relied on being started after
# something it did not declare would break here, which is a reason to declare it, not a reason to
# serialise the whole boot. Verified across reboots with no crashed service, openbao-selfcheck fully
# green and zero AppArmor denials.
sed -i 's|^#\?rc_parallel=.*|rc_parallel="YES"|' /etc/rc.conf
grep -q '^rc_parallel="YES"' /etc/rc.conf || echo 'rc_parallel="YES"' >> /etc/rc.conf

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
# busybox's crond, enabled for exactly one job: bounding the log files.
#
# A scheduler on an appliance is a cost, and it is paid here because the alternative is worse. OpenBao's
# file audit device does not rotate -- upstream says so and says to use an external tool and a SIGHUP --
# and OpenBao refuses requests when every audit device fails to write. At the 5.8 KiB per operation this
# image measures, an unrotated audit log fills a 25 GiB Droplet and takes the secret store down with it.
#
# No package was added for this: crond is busybox, already present, and /etc/crontabs/root already runs
# /etc/periodic/* -- so what is new is a runlevel entry and one script, not a dependency. `logrotate`
# would have been the conventional answer and was rejected: it is a config-parsing C program running as
# root, on an image with no package manager to update it when a CVE lands, to bound one file pattern --
# and enabling it would also make live the three inert /etc/logrotate.d/ files that arrived with other
# packages.
rc-update add crond default
ln -sf /usr/local/sbin/openbao-rotate-logs /etc/periodic/15min/openbao-rotate-logs
test -x /usr/local/sbin/openbao-rotate-logs || {
	echo "FATAL: the log rotator is not executable; the node could fill its own root disk" >&2
	exit 1
}
grep -q 'periodic/15min' /etc/crontabs/root || {
	echo "FATAL: /etc/crontabs/root does not run /etc/periodic/15min; nothing would rotate the logs" >&2
	exit 1
}
# Before sshd, and not trusting tiny-cloud to have done it. See the service for why.
rc-update add cloud-ssh-keys default
rc-update add sshd default
rc-update add openbao-pod-routes default
# The one place that waits for the metadata service and caches what it returns. Everything that needs
# this node's identity declares `need metadata` and reads files, so there is exactly one retry loop on
# the image rather than one per consumer -- see the service for why the wait cannot be a dependency.
rc-update add metadata default
# Split out of openbao's start_pre so a volume that will not mount is reported as a volume that will not
# mount. openbao declares `need openbao-volume`, so it cannot start on the Droplet's own disk by accident.
rc-update add openbao-volume default

# OpenBao IS enabled, unlike the systemd unit in stack's cloud-init, which is installed disabled so the
# operator's TLS step cannot be skipped by a reboot. That reasoning is inverted here on purpose: the
# init script refuses to start without TLS material, so the gate is kept, while a node that reboots
# after TLS is in place comes back on its own. A secret store that stays down after an unattended
# reboot is a worse failure than one that starts too eagerly, and with one node and no quorum that
# reboot is the whole availability story.
rc-update add openbao default
# Last, and the reason it is a service at all: openbao-selfcheck is what turns this image's claims into
# facts, and it used to run only when a human typed it. Its output goes to the serial console, which is
# what DigitalOcean's recovery console shows.
rc-update add openbao-selfcheck default

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

# THERE IS NO DEBUG BUILD, and this note is here so nobody adds one back.
#
# A `mise run debug` task used to bake a root password and a `PasswordAuthentication yes` drop-in into a
# separately named image, because this appliance can boot unreachable and a node nobody can log into
# cannot be diagnosed. It was removed: a build path whose entire purpose is to defeat this image's
# authentication is a permanent invitation, and the two things that justified it are both gone.
#
# What replaced it. The lab under QEMU reproduces a Droplet closely enough to have found every bug the
# debug image was built to chase -- it fakes the metadata service, the `DO`/`Volume` SCSI disk and the
# two-NIC arrangement, and OpenBao has been initialized, unsealed and served through it. And a node that
# is genuinely unreachable is recovered with DigitalOcean's recovery ISO, which boots a rescue system
# with this disk attached and needs nothing baked into the image to work.
#
# scripts/verify-image still asserts the absence of all three artifacts. Those checks now guard against
# reintroduction rather than against releasing the wrong file.

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
#
# Removed by reading apk's own database rather than by listing paths here, and that is not a style
# choice. Every package below is a hard dependency of something the appliance genuinely needs, so
# `apk del` refuses and an `rm` is the only route -- and a hand-written list of paths is how you delete
# /bin/bbsuid and take `mount` with it, which is a mistake this image has already made once. apk
# records every file it installed, symlinks included; this removes exactly those and nothing else.
#
# It also writes its own record. The note appended to /etc/openbao-appliance-packages used to be a
# hand-maintained heredoc listing what had been force-removed, which is a list that drifts the first
# time somebody adds a removal and forgets the second edit. Now the record is produced by the removals.
removed_note=/tmp/removed-note
: > "$removed_note"

purge() {
	reason="$1"
	shift
	# Reason first, then the packages indented under it. Columns were tried and do not survive a list of
	# eight package names; this file is read by somebody working out what was on a node during an
	# incident, so it has to stay legible however long the list gets.
	printf '#   %s:\n#       %s\n' "$reason" "$*" >> "$removed_note"
	for package in "$@"; do
		awk -v want="$package" '
			/^P:/ { name = substr($0, 3) }
			/^F:/ { dir = substr($0, 3) }
			/^R:/ { if (name == want) print "/" dir "/" substr($0, 3) }
		' /lib/apk/db/installed |
			while IFS= read -r file; do
				rm -f "$file"
			done
	done
}

# Python, pulled in by `apparmor` as a hard dependency for its aa-* helper scripts. The appliance uses
# none of them: /etc/init.d/apparmor is a plain OpenRC shell script, and apparmor_parser is a C binary
# that runs fine without an interpreter (verified before this line was written). Leaving it would put a
# 60 MiB scripting runtime on the host holding every production credential, which is the exact thing
# choosing tiny-cloud over cloud-init avoided.
#
# The dependency closure goes with it. This used to remove libsqlite3 and libmpdec and stop there, which
# left libffi, libgdbm, libgdbm_compat, libpanelw, libreadline and libexpat on the image -- an XML
# parser and a database library on an appliance with nothing to call them, kept alive only by the fact
# that nobody had scanned for what still linked them. Nothing does; checked with a NEEDED scan over
# every ELF file in the image.
#
# libstdc++ is NOT in this list and must not be: apparmor_parser links it, and removing it takes
# AppArmor with it. libncursesw is not either: sfdisk links it, and root expansion needs sfdisk.
purge "a hard dependency of apparmor, used only by its aa-* helper scripts" \
	python3 python3-pyc pyc python3-pycache-pyc0
purge "python's dependency closure, with nothing left to link it" \
	sqlite-libs mpdecimal libffi gdbm libpanelw readline libexpat
rm -rf /usr/lib/python3*
/sbin/apparmor_parser --version >/dev/null 2>&1 || {
	echo "FATAL: apparmor_parser stopped working after removing Python" >&2
	exit 1
}

# The tools that put a bootloader on this disk, on a disk that already has one. `syslinux` is installed
# by alpine-make-vm-image to run `extlinux --install`, so it cannot be left out of the package list --
# it is genuinely needed while the image is being built and is dead the moment it is. What remains is a
# bootloader installer, a FAT filesystem editor (mtools) and an ISO rewriter on the host holding every
# production credential. `/usr/share/syslinux`, the payload, was already being removed here; the
# binaries that install it were not.
#
# isohybrid.pl goes with them, and it is worth naming: a Perl script, on an image whose verify step
# asserts there is no interpreter. There is no perl to run it, so it was inert -- but the check looks
# for /usr/bin/perl and would not have found this.
purge "a bootloader installer, on a disk whose bootloader is installed" syslinux mtools
rm -rf /usr/share/syslinux

# e2fsprogs-extra, cut to the one tool that has a caller.
#
# resize2fs is in this subpackage rather than in base e2fsprogs, so it has to be installed -- and it
# arrives with nineteen other tools. `debugfs` is why this block exists rather than being left as
# untidiness: it is a raw ext2/3/4 editor that reads and writes blocks directly, which on this host is a
# way to read the Raft volume around every file permission protecting it, and to write it around the
# AppArmor profile that stops OpenBao itself doing so. It is a fully general filesystem shell on a
# machine that ships no shell.
#
# Measured rather than assumed: the only tool tiny-cloud calls is `resize2fs`, at
# /usr/lib/tiny-cloud/init:86. The `debugfs` hits elsewhere in /etc/init.d are the KERNEL filesystem of
# that name being mounted by OpenRC's sysfs script, not this binary -- which is exactly the kind of
# thing a grep count would have got wrong. chattr and lsattr stay: /etc/init.d/bootmisc calls chattr.
for dead_tool in debugfs badblocks e2image e2undo e4crypt e4defrag e2freefrag filefrag \
	e2scrub e2scrub_all e2mmpstatus mklost+found logsave dumpe2fs e2label; do
	rm -f "/usr/sbin/$dead_tool"
done
printf '#   %s:\n#       %s\n' \
	"raw filesystem editors with no caller; debugfs reads the Raft volume around its permissions" \
	"e2fsprogs-extra (all but resize2fs, chattr, lsattr)" >> "$removed_note"
# libss is debugfs's command-line library and libreadline was linked by nothing else, which is how a
# 292 KiB line editor outlived the interpreter it came in for.
rm -f /usr/lib/libss.so*
test -x /usr/sbin/resize2fs || {
	echo "FATAL: resize2fs was removed; the root filesystem could not grow into the Droplet's disk" >&2
	exit 1
}

# Every virtual-terminal login, for a machine with no keyboard and no password.
#
# Root's password field is `*`, so no password can ever match and a getty on tty1 offers a prompt that
# cannot be passed -- and with the debug build removed there is no longer any way to produce an image
# where it can. It is a login prompt that exists only to be failed at.
#
# This costs nothing an operator uses. DigitalOcean's console still shows the whole boot, including
# openbao-selfcheck's verdict, because that output comes from the kernel and OpenRC rather than from a
# getty. ttyS0 keeps its getty: that is the serial console, and OpenRC writes there.
sed -i '/^tty[1-6]:/d' /etc/inittab
grep -q '^ttyS0:' /etc/inittab || {
	echo "FATAL: the serial console getty was removed; DigitalOcean's console would show nothing" >&2
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
# Kept deliberately: virtio-rng, because this host generates keys and wants entropy; nvme/host, because
# DigitalOcean's storage presentation is not guaranteed to stay virtio-blk; and the whole crypto and
# ipv4/ipv6 trees.
#
# The net/ entries are the ones worth reading twice. Each is a protocol family the kernel will autoload
# the moment anything calls socket() for it -- `socket(AF_KEY, ...)` is four lines of C, needs no
# privilege, and loaded a parser this appliance has no use for. The original pruning covered netfilter,
# sched, sctp, 9p, ceph, sunrpc and bridge and stopped there; these are the rest of the same argument.
#
# nvme/target is the NVMe-over-TCP *target*, a network-facing block protocol server, and it came in with
# the deliberate decision to keep nvme/host. vhost and vdpa are the host side of virtio and do nothing in
# a guest. hv is Hyper-V. arch/x86/kvm is not hypothetical: on the running appliance `lsmod` showed
# kvm_amd and kvm loaded, 1.4 MiB of hypervisor that put itself into the secret store host unasked.
release="$(ls /lib/modules | head -1)"
modules="/lib/modules/$release/kernel"
for dead in sound drivers/gpu drivers/usb drivers/md drivers/hid drivers/input \
            drivers/target drivers/message drivers/xen drivers/bluetooth \
            drivers/nvme/target drivers/vhost drivers/vdpa drivers/hv \
            drivers/cdrom drivers/nvdimm drivers/rpmsg \
            arch/x86/kvm \
            net/netfilter net/sched net/sunrpc net/ceph net/sctp net/bridge net/9p \
            net/key net/llc net/802 net/vmw_vsock net/l2tp net/openvswitch \
            net/mpls net/nsh net/ife; do
	rm -rf "${modules:?}/$dead"
done

# Cut a module directory down to the modules named, AND everything they depend on.
#
# **The dependency closure is the whole point, and leaving it out cost a boot.** The first version of
# this kept `virtio_net.ko*` by name and deleted the rest of drivers/net, which is correct right up
# until you learn that virtio_net depends on net_failover, which lives in that same directory. The
# image built, every offline check passed -- including one asserting virtio_net was still there -- and
# the node came up with `Cannot find device "eth0"`, no network, and therefore no metadata, no SSH and
# no OpenBao. A module is not kept by keeping its file; it is kept by keeping what it loads with.
#
# modules.dep already knows, so it is read rather than guessed. This runs before depmod deliberately:
# the dependency data has to come from the tree as the kernel package shipped it, not from an index
# regenerated over a tree that has already had things taken out of it.
prune_modules() {
	tree="$1"
	shift
	keep=""
	for wanted in "$@"; do
		# The line for this module, whose form is "<path>: <dependency path> <dependency path> ...".
		# Both sides are wanted, so the colon becomes a separator and the whole line is taken.
		dependency_line="$(grep -m1 "/$wanted\.ko" "/lib/modules/$release/modules.dep" || true)"
		[ -n "$dependency_line" ] || {
			echo "FATAL: $wanted is not in modules.dep; the prune would remove it" >&2
			exit 1
		}
		for path in $(printf '%s' "$dependency_line" | tr ':' ' '); do
			keep="$keep ${path##*/}"
		done
	done

	find "$modules/$tree" -type f -name '*.ko*' | while IFS= read -r module_file; do
		case " $keep " in
		*" ${module_file##*/} "*) ;;
		*) rm -f "$module_file" ;;
		esac
	done
	find "$modules/$tree" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# Every network driver except virtio_net and what it loads with, which is 3.2 MiB and the largest
# single tree left.
#
# A Droplet's NIC is virtio, so what this removes is drivers for hardware that cannot be attached to
# this machine -- 1.9 MiB of physical NIC drivers alone, Mellanox and Intel and the cloud vendors' own.
# The rest is the interesting part and the reason this is a security change before a size one: bonding,
# team, vxlan, macsec, ipvlan, ppp, slip, wireguard, ovpn and tun are encapsulation and tunnel drivers,
# each one a parser the kernel will autoload the moment something asks for that link type. None of them
# has a caller here; this node routes plain IP over virtio and nothing else.
#
# The same bet as `drivers/nvme/host` being kept, made in the other direction and worth saying so: that
# one hedges against DigitalOcean changing its storage presentation, this one does not hedge against it
# changing its network presentation. The boot test is what makes that safe to assert -- it boots against
# virtio-net-pci and the node is unreachable if this is ever wrong, which is not hypothetical: that is
# how the missing net_failover above was found.
prune_modules drivers/net virtio_net

# The SCSI tree, cut to what reaches a DigitalOcean volume: virtio_scsi for the transport and sd_mod for
# the disk, plus their dependencies. `scsi_mod` is builtin in linux-virt, so it is not in here to keep.
#
# What goes is every other transport the kernel could bind: iSCSI, Fibre Channel, SAS, SRP, SPI, the LSI
# Fusion driver, Xen and Hyper-V storage fronts. `sg` goes with them and is the one to notice -- SCSI
# generic passes arbitrary SCSI commands straight to a device, which on this host means straight to the
# disk holding the Raft store. `sr_mod` is the CD-ROM driver, on a machine with no optical drive.
prune_modules drivers/scsi virtio_scsi sd_mod

# Every filesystem except the one this appliance uses. ext4 needs jbd2 and mbcache beside it.
find "$modules/fs" -mindepth 1 -maxdepth 1 \
	! -name ext4 ! -name jbd2 ! -name 'mbcache*' -exec rm -rf {} + 2>/dev/null || true

# modules.dep still describes what was deleted, and a stale dependency file makes modprobe fail in a way
# that reads as a missing driver rather than a stale index.
#
# Its warnings are an error here, not noise. `depmod` reports a module left with a dependency that is no
# longer on disk as `needs unknown symbol`, and that is precisely the state a prune produces when it
# takes something out from under a module it meant to keep -- so the one tool that can see the mistake
# is made to fail on it. Nothing else can: the file is present, every offline check finds it, and the
# module simply refuses to load at boot.
depmod_warnings="$(depmod -a "$release" 2>&1 || true)"
if [ -n "$depmod_warnings" ]; then
	echo "FATAL: the module prune left unresolved dependencies:" >&2
	printf '%s\n' "$depmod_warnings" >&2
	exit 1
fi

# And the same question asked directly of the modules this appliance cannot boot without: every path on
# their modules.dep line has to still exist. depmod's warnings cover a module that lost a symbol; this
# covers one that lost a whole dependency file, which is what happened to virtio_net.
for critical in virtio_net virtio_blk virtio_scsi sd_mod ext4; do
	dependency_line="$(grep -m1 "/$critical\.ko" "/lib/modules/$release/modules.dep" || true)"
	[ -n "$dependency_line" ] || {
		echo "FATAL: $critical is gone from modules.dep; this node would boot without it" >&2
		exit 1
	}
	for path in $(printf '%s' "$dependency_line" | tr ':' ' '); do
		[ -f "/lib/modules/$release/$path" ] || {
			echo "FATAL: $critical needs $path, which the module prune removed" >&2
			exit 1
		}
	done
done

# **The initramfs is generated when the kernel package is installed, which is before this script runs.**
# So every module pruned above was still inside it, and the image's central claim about modules -- that
# one which is not on disk cannot be loaded -- was true of the root filesystem and false of the boot
# medium sitting beside it. Measured on the built image: 1.4 MiB of GPU drivers, 724 KiB of USB, 228 KiB
# of RAID, 184 KiB of HID and the whole filesystem tree, all present in /boot/initramfs-virt after
# setup.sh had removed them from /lib/modules, and all of it loadable by the initramfs before
# switch_root ever happens.
#
# Regenerating here, after the prune, is what makes the two agree. mkinitfs reads the same feature list
# it was configured with (base ext4 scsi virtio) and copies what those globs still match, so this needs
# no separate list to keep in step -- the prune above is the single source of truth and this follows it.
#
# Asserted rather than trusted, because an initramfs missing virtio_blk or ext4 is an image that cannot
# mount its own root and says nothing until it is booted.
mkinitfs -o /boot/initramfs-virt "$release" 2>&1 | grep -Fv 'cannot open device /dev' || true
for required in virtio_blk ext4 virtio_scsi; do
	gzip -dc /boot/initramfs-virt | cpio -it 2>/dev/null | grep -q "$required" || {
		echo "FATAL: the regenerated initramfs has no $required; this image cannot mount its root" >&2
		exit 1
	}
done
echo "    initramfs: $(( $(stat -c %s /boot/initramfs-virt) / 1024 )) KiB after pruning"

# The initramfs toolchain, which exists to produce the file above and has now produced it. Nothing on a
# running node regenerates an initramfs, because nothing on a running node updates a kernel -- there is
# no package manager to do it with, and a security update here means a new image and a new Droplet.
#
# This is where cryptsetup and device-mapper leave the appliance. They are on it because mkinitfs links
# libcryptsetup for `nlplug-findfs`, the initramfs's device finder, so an image that mounts one plain
# ext4 filesystem was carrying a full disk-encryption and device-mapper stack for a program that only
# ever runs inside an initramfs. lddtree, scanelf, yx and libyaml are mkinitfs's own build-time helpers.
purge "the initramfs toolchain, after the initramfs it builds" \
	mkinitfs lddtree scanelf yx yaml cryptsetup-libs device-mapper-libs json-c
rm -rf /usr/share/mkinitfs /etc/mkinitfs

# The kernel symbol map, which exists to decode an oops on a machine with a debugger attached. This one
# sets ptrace_scope=3 and has no debugger, and the file is 6.1 MiB.
rm -f /boot/System.map-*

# The kernel's build configuration, and the extlinux configuration as it stood before setup.sh rewrote
# the command line. Both are pure description of a machine an attacker is standing on: the first says
# exactly which features and mitigations this kernel was compiled with, the second says what the boot
# looked like before it was hardened.
rm -f /boot/config-* /boot/extlinux.conf.old

# The package record above was written while apk still worked, so it lists what apk installed rather
# than what survives on the running node. Every removal in this section is a force-deletion rather than
# an `apk del` -- each is a hard dependency of something the appliance does need -- so apk's database
# still believes those files are present. Recording the difference is what keeps the file honest for an
# incident response, which on an image with no package manager has nothing else to read.
#
# Written from the note the removals produced, not from a list maintained beside them.
{
	echo
	echo "# Force-removed after installation; apk's database above still lists them as installed:"
	cat "$removed_note"
	printf '#   %s:\n#       %s\n' \
		"the setuid bit removed, the binary left in place; nothing runs as a non-root human" \
		"busybox-suid (/bin/bbsuid)"
	printf '#   %s:\n#       %s\n' \
		"removed last; this image is replaced, never patched in place" \
		"apk-tools (/sbin/apk, libapk, /usr/share/apk)"
} >> /etc/openbao-appliance-packages

# After the record is written, not before: the note lives in /tmp and this wipes it. Doing these two in
# the other order cost a build -- the record read a file that had just been deleted, setup.sh died, and
# `build:assert` refused the half-hardened image on the strength of its missing stamp, which is exactly
# the failure that check was added for.
rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true

# apk itself, last, because everything above needed it.
#
# This is what makes the appliance immutable rather than merely minimal: a node cannot be patched in
# place, and a security update means building a new image and replacing the Droplet. That is the
# intended operating model, and it is the reason /etc/openbao-appliance-packages is written above --
# with no package manager, that file is the only record of what is installed.
#
# The library goes with the binary. Removing /sbin/apk and leaving libapk.so behind is half the job:
# what makes this appliance immutable is that there is no code on it that can install a package, and a
# shared object that does exactly that is code whether or not the front end is still there.
#
# /lib/apk/db is deliberately kept: it is data rather than code, it is readable without apk, and it is
# what an incident response reads to find out what was on the node.
rm -f /sbin/apk /usr/lib/libapk.so*
rm -rf /usr/share/apk

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

# The stamp that makes this script's failure visible to the build, and it is not a formality.
#
# alpine-make-vm-image reports a failed chroot script as `ERROR: Script failed` and still exits 0 --
# measured, by failing this script deliberately. The build then compacted the half-finished image, and
# `build:assert` passed it, because a partial image still contains the 186 MiB bao binary and clears the
# 200 MiB floor that check was written for. So a build that stopped halfway through hardening produced an
# artifact indistinguishable from a good one, at the exit code and at the size.
#
# /mnt is the stage directory bind-mounted into the chroot, so writing here puts the stamp where the host
# can see it the moment the build returns. build:image removes it before every run.
: > /mnt/setup-complete

echo "==> setup complete"
