# Audit — 2026-08-11, second pass

A security, flexibility, size and traceability review of the appliance image, against commit `3330764`
and following [`audit-2026-08-11.md`](audit-2026-08-11.md), whose findings were already acted on.

Everything below was **built, verified and booted**, and the image was driven end to end in the lab: a
QEMU guest with a SCSI disk presenting as vendor `DO` model `Volume`, a metadata service on
`169.254.169.254`, and two NICs. OpenBao was initialized, unsealed, written to and read from, its audit
log rotated, and the node rebooted with the store intact — with **zero AppArmor denials against the
server** throughout.

The lab is not a Droplet. Nothing here has run on DigitalOcean.

## What changed, by weight

| | Before | After |
| --- | --- | --- |
| packages | 109 | 93 |
| kernel modules | 370, 11 MiB | 293, 6.4 MiB |
| initramfs | 10,270 KiB | 5,440 KiB |
| image | 219 MiB | 201 MiB |
| compressed | 95 MiB | 71 MiB |
| offline checks | 116 | 166 |

Size was the least of it. The reason to read this is the two defects in the middle.

## The two defects

### 1. The initramfs kept everything the build removed

`setup.sh` prunes `/lib/modules` and has since the image existed. The initramfs is generated when the
kernel package is installed, which is **before the chroot script runs**, and nothing regenerated it — so
`/boot/initramfs-virt` still contained 1.4 MiB of GPU drivers, 724 KiB of USB, 228 KiB of RAID, 184 KiB
of HID and the entire filesystem tree, every one of which the build had carefully deleted from the root
filesystem and `verify-image` asserted absent.

The image's central claim about modules — *a module that is not on disk cannot be autoloaded* — was
therefore true of the root filesystem and false of the boot medium next to it. The practical exposure is
narrow, because `switch_root` discards the initramfs and those modules are unreachable afterwards. The
gap between a claim and its assertion is the finding.

`setup.sh` now regenerates the initramfs after the prune, asserts the result still carries `virtio_blk`,
`ext4` and `virtio_scsi`, and `verify-image` lists the archive and checks the pruned trees are gone.
That halved it.

### 2. The TLS gate could not start any node but the default one

`start_pre()` required three literal paths under `/var/lib/openbao/tls`. `README.md` invites replacing
`10-listener.hcl` with an ACME listener; OpenBao supports `tls_disable` for a node behind a terminating
proxy. **Both were impossible.** The service refused to start, naming files the operator had
deliberately not created — and the README documented a path that could not work.

The gate now reads `tls_cert_file`, `tls_key_file` and `tls_client_ca_file` out of the loaded fragments
and requires whatever they name. Fail-closed is unchanged and is the point of the gate; what changed is
that it is now closed against the configuration in force rather than against the image's own default.
It is also stricter for an operator who moved the files, which previously passed the gate and then
failed inside OpenBao.

`user_data` is now read into `/run/openbao/config.d` **before** the gate, because a listener supplied
that way has to count. Verified in the lab: a `tls_disable` listener starts; a named certificate that is
absent still refuses, and names the file.

## Security

**Removed, with a caller checked for in every case.** The OpenSSH client suite (2.2 MiB — every session
this node takes part in is inbound), `tc`/`ss`/`bridge`/`genl`/`libxtables`, the syslinux and mtools
bootloader installers, the mkinitfs toolchain and with it the cryptsetup and device-mapper stack that
`nlplug-findfs` links, `debugfs` and the other raw ext editors, Python's orphaned dependency closure
(`libffi`, `libgdbm`, `libpanelw`, `libreadline`, `libexpat` — the previous removal listed two
libraries and stopped), and `libapk`.

`debugfs` is the one worth naming: a raw ext2/3/4 editor reads and writes the Raft volume's blocks
around every file permission on it, and around the AppArmor profile that stops OpenBao itself doing so.
It is a general filesystem shell on a machine that ships no shell. `resize2fs` is in the same subpackage
and is genuinely needed, so the tools are removed individually and `resize2fs` is asserted present.

Removals now read apk's own database rather than a hand-written path list — the mistake that once
deleted `/bin/bbsuid` and took `mount` with it — and each one writes its own line into
`/etc/openbao-appliance-packages`, so the record is produced by the removals instead of maintained
beside them.

**Kernel surface.** `drivers/net` is cut to `virtio_net` and its dependency closure, which removes
1.9 MiB of physical NIC drivers and, more to the point, the tunnel and encapsulation drivers — `ppp`,
`slip`, `wireguard`, `ovpn`, `vxlan`, `macsec`, `tun`, `bonding`, `team` — each a parser the kernel
autoloads the moment something asks for that link type. `drivers/scsi` is cut to `virtio_scsi` and
`sd_mod`, which removes the iSCSI, Fibre Channel, SAS, SRP and SPI transports and `sg`, the SCSI
generic passthrough that would send arbitrary SCSI commands to the disk holding the store.

**Host.** `user.max_user_namespaces=0` — the largest piece of kernel attack surface an unprivileged
process can reach, and nothing here uses one; verified on the running node, where `unshare --user` fails.
`fs.protected_symlinks`, `protected_hardlinks`, `protected_fifos`, `protected_regular`. sshd gains
`AllowStreamLocalForwarding no`, `MaxStartups 4:30:16` and `LogLevel VERBOSE`, the last so the
fingerprint of the key that authenticated is recorded — on a node whose only account is shared root,
that is the only attribution available. The AppArmor profile gains an audited denial on writes to the
seal key, which forbids nothing new and makes an attempt visible in `dmesg` rather than silent.

## Flexibility

This image is advertised for other people to boot, so a default is not a decision to make for them.
Both changes keep the accident impossible and make the deliberate choice reachable.

- The TLS gate, above: ACME, `tls_disable` and relocated certificates all start.
- `RAFT_DEVICE="none"` in `/etc/conf.d/openbao-volume` runs the store on the Droplet's own disk. The
  default still refuses to start when it cannot find exactly one volume, because OpenBao quietly writing
  Raft to the boot disk while an attached volume sits empty is the one failure a secret store cannot
  absorb — but that is an accident, and this is a statement. The warning repeats on every boot and
  `openbao-selfcheck` reports it as what it costs rather than as a fault.

## Ease of use

**Nothing set `BAO_CACERT`**, so the first `bao status` anybody ran on a node answered `x509: certificate
signed by unknown authority`, and the documented way out of that is `-tls-skip-verify` — the flag that
turns off certificate verification on the host holding every production credential. `AGENTS.md` already
said anything that makes an operator reach for it is a bug in this image. It was one.

`/etc/profile.d/openbao.sh` derives `BAO_ADDR` and `BAO_CACERT` from the loaded configuration. Measured
in the lab, on the same node, one command apart:

```
with the profile:     bao status -> Seal Type shamir, Initialized false, Sealed true
without it:           Error checking seal status: ... x509: certificate signed by unknown authority
```

`BAO_ADDR` is the address OpenBao advertises to its clients, not the loopback: that is the address the
certificate has to be valid for, since otherwise nothing else could connect either.

`openbao-selfcheck` gained a third TLS state. It reported "certificate file" or "ACME" and nothing else,
which was complete only while the gate refused everything else — a `tls_disable` node would have been
described as fetching certificates from a public CA while serving plaintext.

## Auditability

`mise.linux-x64.lock` is committed and `locked = true`, so both build inputs resolve through it —
version, URL and checksum, per platform. `locked_verify_provenance = true` checks a tool's build
attestation rather than only its checksum. The hand-maintained `bao_sha256` stays, and the comment now
says why it is not redundant: the lockfile records the release **archive**, this records the **binary**
extracted from it, and between the two sit an extraction and a writable cache on the build host.

`/etc/openbao-appliance-release` records the source commit, Alpine branch, OpenBao version and build
date; `verify-image` copies it out beside the artifact and the release notes publish it. The release
workflow attests the published file with `actions/attest-build-provenance`, so where an image came from
can be checked by someone who has only the file.

A `Check` workflow now runs lint, build, verify and the boot test on every push and pull request, and
fails if the lockfile is stale. Before it, nothing ran automatically except at release time.

## What the boot test caught

The first `drivers/net` prune kept `virtio_net.ko` by name. `virtio_net` loads with `net_failover`,
which lives in the same directory. The image built, **every offline check passed** — including one
asserting `virtio_net` was present — and the node came up with `Cannot find device "eth0"`: no network,
therefore no metadata, no SSH, no OpenBao.

The prune now reads the dependency closure out of `modules.dep`, the build treats any `depmod` warning
as fatal, and `verify-image` asserts both the closure and that every dependency file still exists. The
check that failed was replaced too: it demanded that `drivers/net` contain nothing but `virtio_net`,
which is exactly the assertion that had to be wrong for the image to be right.

## Still unsettled

- **Never booted on a real Droplet.** Unchanged, and now the largest gap by some distance.
- No credential minted against a real PostgreSQL instance; Agent injection from a cluster unexercised.
- `mitigations=auto,nosmt` is still not on the kernel command line. It can prevent boot; add it alone,
  with a boot test.
- `drivers/net` being cut to virtio is a bet that DigitalOcean's network presentation does not change —
  the opposite of the bet made for storage, where `drivers/nvme/host` is deliberately kept. Both are
  stated in `setup.sh`; only one can be right if the presentation ever changes.
- The image still carries `libcrypto` (4.8 MiB) and `libstdc++` (2.7 MiB), for sshd and
  `apparmor_parser`. Neither is removable without removing what links it.
