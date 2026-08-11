# Audit — 2026-08-11, second pass

A security, flexibility, size and traceability review of the appliance image, against commit `3330764`
and following [`audit-2026-08-11.md`](audit-2026-08-11.md), whose findings were already acted on.

Everything below was **built, verified and booted**, and the image was driven end to end in the lab: a
QEMU guest with a SCSI disk presenting as vendor `DO` model `Volume`, a metadata service on
`169.254.169.254`, and two NICs. OpenBao was initialized, unsealed, written to and read from, its audit
log rotated, and the node rebooted with the store intact — with **zero AppArmor denials against the
server** throughout.

**It has since run on DigitalOcean.** See "On a real Droplet" at the end: a `s-1vcpu-1gb` in `lon1`
built from the published release, boot to SSH in 6.5 seconds, zero AppArmor denials, store intact
across a reboot.

## What changed, by weight

| | Before | After |
| --- | --- | --- |
| packages | 109 | 93 |
| kernel modules | 370, 11 MiB | 293, 6.4 MiB |
| initramfs | 10,270 KiB | 5,440 KiB |
| image content | 201 MiB | 185 MiB |
| compressed | 95 MiB | 82 MiB |
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

## Boot time, and what it is actually made of

Measured on a steady-state reboot in the lab, against the guest's own clock. **The absolute numbers are
emulation and mean nothing** — this is TCG on an ARM host, roughly an order of magnitude off native — but
the split between phases and the effect of a change are both real.

| | Before | After |
| --- | --- | --- |
| SSH answering | 52s | 42s |
| port 8200 listening | 60s | 48s |

The only change was `rc_parallel="YES"`. OpenRC serialises the whole boot by default, so services with no
relationship to each other waited for each other — DHCP on two interfaces, chronyd, crond and sshd have
no reason to be sequential. It is safe here only because this image declares its dependencies with
`need` rather than relying on start order. Verified over repeated reboots: no crashed service,
`openbao-selfcheck` fully green, zero AppArmor denials.

Where the rest goes, from `dmesg` gaps over 0.5s:

```
 4.89 ->  6.98  (+2.09s)  kernel init, X.509 keyring
 7.48 ->  8.41  (+0.93s)  initramfs starting
11.90 -> 14.65  (+2.74s)  root filesystem mount
14.66 -> 20.91  (+6.25s)  device coldplug
22.98 -> 25.19  (+2.20s)  AppArmor profile load
25.57 -> 30.32  (+4.75s)  Raft volume mount
```

**Two things were tried and rejected.** Removing `hwdrivers` — the 6.25s coldplug, the largest single
gap — changed nothing measurable, because `mdev` does the work either way; and it is what loads
`virtio_rng`, which is entropy on a host that generates keys. Trimming the runlevels found nothing else
worth removing: `swap` is a no-op on an image with no swap, and every other service has a caller.

The honest conclusion is that the boot is not obviously slow. What makes it *look* slow is where it is
usually watched, and that turned out to be a fixable mistake rather than a fact.

**GitHub-hosted runners do have KVM.** The first version of this section said they did not, on the
strength of a comment in `release.yaml` that had been carried for months. Probed instead: an
`ubuntu-24.04` runner is an AMD EPYC 9V74 with `svm`, the `kvm` modules loaded and `/dev/kvm` present --
owned `root:kvm`, mode 0660, and the runner user is not in that group. So QEMU fell back to TCG and the
boot test emulated an x86 machine on x86 hardware, silently, because nothing reported which accelerator
was in use. A one-line udev rule fixes it, and `boot:run` now prints the answer so it cannot regress
into "slow for a reason nobody checked".

## Readiness

DigitalOcean has no readiness hook. A Droplet is `active` as soon as the hypervisor has started it,
there is no callback, and nothing in `/etc/init.d` can change that — OpenRC reports a service `started`
the moment `supervise-daemon` spawns it, which here is true while the node is sealed and serving
nothing. `rc-service openbao status` says "started" throughout.

The signal is OpenBao's own `/v1/sys/health`: 200 ready, 429 standby, 501 uninitialized, 503 sealed.
Measured against 2.6.1 on the lab node — 200 unsealed, 503 after a restart. A DigitalOcean Load Balancer
health check is the closest thing to the provider knowing; Terraform can poll the same path.

`openbao-selfcheck` now reports it too, at the end of every boot, onto the serial console the recovery
console shows — the one place an operator can see "sealed, waiting for you" without first being able to
log in. All four states were exercised: not running, running but uninitialized, initialized but sealed,
and ready.

And the part no boot-time tuning reaches: **with the default Shamir seal a node cannot become ready on
its own**, because unsealing needs a human with key shares. A Droplet that boots straight into service
is a seal decision, not a performance one.

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

## On a real Droplet

The standing gap in every previous audit, closed. A `s-1vcpu-1gb` in `lon1`, created from the
`2026.08.11.6` release asset imported straight from GitHub — the repository is public, so DigitalOcean's
unauthenticated fetcher can reach it — with a 1 GiB volume attached.

| | Lab (TCG) | **Real Droplet** |
| --- | --- | --- |
| boot to SSH | 42s | **6.5s** |
| reboot with a live store | 42s | **7.2s** |
| kernel init done | 6.1s | 2.3s |
| root mounted | 13.0s | 2.8s |
| `crng init done` | 3.3s (with virtio-rng) | **0.04s** |

Everything the lab claimed held: the Raft volume was found through sysfs as `/dev/sda`, the two-NIC
arrangement is real (`eth0` public, `eth1` VPC), tiny-cloud grew the 1 GiB image to 24.6 GiB, the
operator's key arrived from the metadata service, AppArmor came up enforcing, and OpenBao was
initialised, unsealed, served KV v2, took a policy and an AppRole, wrote audit records and survived a
reboot with the secret intact. **Zero AppArmor denials across all of it.** `bao status` worked over SSH
with nothing set by hand and no `-tls-skip-verify`, and `GET /v1/sys/health` answered `200` from the
public internet.

Two findings worth keeping:

**The boot was never slow.** 6.5 seconds. Every larger figure in this repository's history is emulation
— `mise run boot` on an Apple Silicon Mac is TCG, and CI was TCG too until `/dev/kvm` was made usable.
Tuning was still worth doing, but the thing being tuned was the measurement.

**DigitalOcean presents no `virtio-rng`, and entropy is immediate anyway** — `crng init done` at 40
milliseconds, with no `virtio_rng` module loaded and no `hw_random` device. So the 13.9-second entropy
stall the QEMU boot test used to suffer is a property of the lab, not of a Droplet, and the fix for it
belongs where it was made: in the test harness. Nothing about the image needs to change for entropy.

One gap this exposed in the work above: the self-check printed its boot time to the serial console and
nowhere else, so on a node that was up and reachable there was no way to ask what its boot had cost.
It now goes to syslog as well.

## Integration, on real infrastructure

The two paths every previous audit listed as untested, closed the same day as the Droplet boot. Both ran
against a `s-1vcpu-1gb` appliance in `lon1`, a managed PostgreSQL 17, and a single-node DOKS cluster in
the same VPC. Everything was destroyed afterwards.

### The database secrets engine mints against a real PostgreSQL

Configured with `sslmode=verify-full`, a role created, and a credential minted with a one-hour renewable
lease. The credential was then used to log in to the database from a pod, which reported itself as
`v-root-app-…` and confirmed exactly one dynamic role existed. **Zero AppArmor denials** — the engine
loads in-process and the profile's blanket exec denial is not in its way, which had been assumed and is
now measured.

**`ca-certificates` does not verify a DigitalOcean managed database, and `image/packages` claimed it
did.** DigitalOcean signs them with a per-project private CA — `CN=<project-uuid> Project CA` — so the
first attempt failed with `x509: certificate signed by unknown authority`. The correct configuration
installs the project CA on the node and names it with `sslrootcert=`. The entry has been rewritten to
say so, because the alternative an operator reaches for is `sslmode=require`, which verifies nothing on
the connection that mints database credentials.

**Operator-supplied files must live under `/etc/openbao`.** `bao write ... @/tmp/k8s-ca.crt` was denied:
the profile attaches to the binary, confines the CLI, and grants no read on `/tmp`. It is the same shape
as a Raft snapshot not being writable on the node, and it produced the only AppArmor denial recorded all
day — one that was deliberately provoked.

### A pod reaches OpenBao only once the route is installed

This is D20, reproduced and then fixed on real infrastructure rather than argued about.

```
pod -> https://10.106.0.5:8200/v1/sys/health        HTTP 000     (no route)
echo "10.107.0.0/25 10.106.0.7" > /etc/openbao/pod-routes
rc-service openbao-pod-routes restart               10.107.0.0/25 via 10.106.0.7 dev eth1
pod -> https://10.106.0.5:8200/v1/sys/health        HTTP 200
```

The Droplet's routing table before showed exactly the described failure: `default via <public gateway>
dev eth0` and nothing for the pod range, so replies went out the public interface and vanished.

**Pod traffic is not masqueraded**, which is the premise the whole mechanism rests on and had never been
checked: the audit log records `remote_address` of `10.107.0.30` and `10.107.0.47` — pod addresses, not
the node's. That also retroactively justifies `net.ipv4.conf.all.rp_filter=2`; strict mode would drop
those packets silently.

### The Agent works, from a sidecar

The real `bao agent` ran as an init container — which is precisely what the injector injects — with
`auto_auth` against the Kubernetes method and a `template` stanza. It authenticated with the pod's
service account, wrote its token to a sink and templated the secret to a shared volume, and the
application container read `minted-through-kubernetes-auth` out of it. A path the policy did not grant
returned 403.

Nothing about Agent injection needs anything from this image that was not already there. What needed
proving was the network path and the auth method, and both hold.