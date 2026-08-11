# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a symlink to this file.

`openbao-droplet-image` builds one artifact: the DigitalOcean custom image the Transitboard OpenBao
Droplets boot. It is an Alpine appliance running OpenBao directly on the host, with no container
runtime, replacing the Debian-plus-podman arrangement that
`stack/infrastructure/platform/cloud-init.yaml.tftpl` builds at first boot.

It versions independently of `stack`. `stack` consumes the published image by slug; nothing here imports
anything from there.

**There is no `mise.toml`, deliberately.** The only configuration is `mise.linux-x64.toml`, selected by
platform because `.miserc.toml` sets `auto_env = true`. The image can only be assembled on linux-x64 —
it mounts an ext4 filesystem and chroots into it — and a half-working setup elsewhere is worth less than
none. On macOS this directory has no tasks at all. Do not add a `mise.toml` to "make it work locally".

## Layout

| Path | Holds |
| --- | --- |
| `mise.linux-x64.toml` | every pin, every task, and the only configuration there is |
| `.miserc.toml` | `auto_env = true`, which is what selects the file above by platform |
| `image/packages` | what is installed, and why each entry earns its place |
| `image/setup.sh` | what happens inside the chroot: users, kernel command line, services |
| `image/overlay/` | files copied into the image verbatim |
| `scripts/verify-image` | offline assertions against a built image, and the package manifest |
| `documentation/` | point-in-time audits; the standing guidance is this file and `README.md` |
| `.github/workflows/` | the manual release pipeline |

## The things most likely to be got wrong

Every one of these was got wrong here first, and most of them looked correct until the image was run —
on a real Droplet, or under a lab imitating one. Reading the recipe cannot reach any of them.

**AppArmor is compiled in but not enabled by default.** `linux-virt` sets
`CONFIG_SECURITY_APPARMOR=y` and ships
`CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity"` — apparmor is absent from the active
stack. Without `lsm=...,apparmor apparmor=1` on the kernel command line, `apparmor_parser` loads the
profile without complaint, `aa-status` reports nothing, and OpenBao runs unconfined. It fails open and
it fails silently. `image/setup.sh` sets it and asserts it reached `/boot/extlinux.conf`;
`scripts/verify-image` asserts it again offline; `openbao-selfcheck` asserts the running process is
genuinely confined. Do not remove any of the three.

**OpenBao 2.x has dropped mlock, so do not reach for `CAP_IPC_LOCK`.** This image used to grant it
ambiently and the AppArmor profile used to allow it, on the reasoning that mlock was the one thing the
container arrangement structurally could not do. That reasoning is dead: `disable_mlock = false` is now
a fatal configuration error (`OpenBao has dropped support for mlock … disable or encrypt swap
instead`), and a Droplet with the grant fully applied — `CapAmb: 0000000000004000` — still showed
`VmLck: 0`, because there is no longer any code in OpenBao to use it.

What stands in its place is the absence of swap, which is upstream's own advice. That makes
`no swap active` in `openbao-selfcheck` load-bearing rather than hygiene. Adding swap to this image
would silently undo the property mlock used to provide.

**The Raft volume is found through sysfs, not `/dev/disk/by-id`.** DigitalOcean documents
`/dev/disk/by-id/scsi-0DO_Volume_<name>`, and it exists on their Debian and Ubuntu images because those
run udev. This image runs `mdev`, which populates `by-label`, `by-uuid` and `by-partlabel` from blkid
and leaves `by-id` **empty** — so the documented glob matched nothing on a Droplet whose volume was
attached and healthy. `start_pre()` scans `/sys/block/sd*` for SCSI vendor `DO`, model `Volume`
instead, and still refuses to guess unless there is exactly one match.

**`deny` beats `allow` in AppArmor, regardless of specificity.** A blanket `deny /** w` in the profile
would override the `/var/lib/openbao/** rwk` grant and OpenBao could not write its own Raft store.
Confinement comes from the whitelist, not from blanket denials.

**The rule is about blanket denials, not about denials** — it used to say "only `deny /** x` is safe" and
that was too strong. A deny scoped to a path nothing is meant to write is exactly right, and the profile
now carries one: `deny /var/lib/openbao/tls/** w`, because TLS moved onto the Raft volume and the `rwk`
grant above it would otherwise let OpenBao rewrite its own private key. What makes that safe is that it
overrides no grant anything needs; what made `deny /** w` unsafe is that it overrode one. Check what a
deny would shadow before adding it, and keep denials narrow.

**Pruning a module means pruning what it loads with.** `virtio_net` depends on `net_failover`, which
lives in the same directory — so a prune that keeps `virtio_net.ko` by name and deletes the rest of
`drivers/net` produces an image where every offline check passes, `virtio_net` is demonstrably present,
and the node boots with `Cannot find device "eth0"`: no network, therefore no metadata, no SSH and no
OpenBao. `prune_modules` in `image/setup.sh` reads the closure out of `modules.dep` and both
`verify-image` and the build assert it independently, the build by treating any `depmod` warning as
fatal. Do not prune by name.

**The initramfs is built before `setup.sh` runs, so pruning `/lib/modules` does not touch it.** For as
long as this image existed, every module the build removed was still in `/boot/initramfs-virt` — 1.4 MiB
of GPU drivers, 724 KiB of USB, the whole filesystem tree — and the rule above was true of the root
filesystem and false of the boot medium beside it. `setup.sh` now regenerates the initramfs *after* the
prune, which is what makes the two agree and which halved it. Anything that changes the module tree must
stay on the correct side of that regeneration.

**The TLS gate reads the configuration; it must never go back to a fixed path.** `start_pre()` requires
whatever `tls_cert_file`, `tls_key_file` and `tls_client_ca_file` the loaded fragments name. It used to
test three literal paths under `/var/lib/openbao/tls`, which was right for the default and refused every
other arrangement — including the ACME listener `README.md` invites, and `tls_disable` for a node behind
a terminating proxy. An image other people boot cannot gate on its own defaults. The fail-closed
property is unchanged and is what the gate is for: a named certificate that is not there is still a
refusal, and it now names the file rather than the image's assumption. `user_data` is read into
`/run/openbao/config.d` **before** the gate, or a listener supplied that way is invisible to it.

**A dependency cannot be declared on the metadata service, so exactly one service waits for it.**
`need net` means an interface is configured. It cannot mean "the hypervisor is answering HTTP on
`169.254.169.254`", because that endpoint is not a service on this machine and OpenRC has no handle on
it — and DHCP completing does not imply the metadata service is serving. So the wait is a retry loop, and
it lives in `/etc/init.d/metadata`, which caches what it reads to `/run/metadata` and `provide`s a
virtual. `cloud-ssh-keys` and `openbao` declare `need metadata` and read files; neither contains a URL.
Do not give a consumer its own fetch. That is what was here before, and the two copies diverged — one
retried fifteen times, the other tried once and produced a node that answered on port 22 with no secret
store. Assert the wait once, or it will be got wrong twice.

**Anything that makes an operator reach for `-tls-skip-verify` is a bug in this image, and for a long
time the image was that bug.** Nothing set `BAO_CACERT`, so the first `bao status` anybody ran on a node
answered `x509: certificate signed by unknown authority`, and the documented way out of that is the flag
that turns off certificate verification on the host holding every production credential.
`/etc/profile.d/openbao.sh` now derives `BAO_ADDR` and `BAO_CACERT` from the loaded configuration — read
rather than hard-coded, so it stays right for a node whose operator moved the files or uses ACME. It is
sourced by login shells only; `ssh <node> <command>` runs a non-login shell and does not get it.

**A file handed to `bao write ... @path` must live under `/etc/openbao`, and `ca-certificates` does not
verify a DigitalOcean managed database.** Two findings from the first real integration, and both look
like bugs in something else when you hit them.

The profile grants no read on `/tmp`, so `scp`ing a CA there and writing it into a configuration answers
`permission denied` on a file that is plainly present — measured, configuring the Kubernetes auth
method. Put operator-supplied material under `/etc/openbao`, which the profile grants `r`.

And DigitalOcean signs managed databases with a per-project private CA, not a public one, so
`sslmode=verify-full` against the shipped bundle fails with `x509: certificate signed by unknown
authority`. The fix is `doctl databases get-ca` into `/etc/openbao/postgres-ca.crt` and `sslrootcert=`
in the connection string — **not** `sslmode=require`, which would verify nothing on the connection that
mints database credentials. `image/packages` used to claim `ca-certificates` covered this; it does not.

**Pod traffic arrives un-masqueraded, which is why `openbao-pod-routes` and `rp_filter=2` both exist.**
Measured on DOKS: OpenBao's audit log records pod-CIDR source addresses (`10.107.0.30`), not the node's.
A pod could not reach the Droplet at all until the return route was installed — `HTTP 000` before,
`HTTP 200` after. Strict reverse-path filtering would drop those packets silently, which is exactly the
symptom D20 spent two wrong fixes chasing.

**The AppArmor profile confines the CLI as well as the server, because a profile attaches to a path.**
`profile openbao /usr/sbin/bao` covers every execution of that binary, including the one an operator
types. This is not a mistake to fix by adding a second unconfined path — it is a property to design
around, and two things follow from it. Everything OpenBao reads is `root:openbao 0750` rather than
`65532:65532 0700` precisely so a confined root can read the CA without a capability; owning the
directory by uid also meant OpenBao could rewrite its own private key, which it now cannot. **That is
also why TLS could move to the Raft volume**: the mountpoint is root-owned with group read and Raft gets
`data/` to itself, where a 0700 mountpoint owned by 65532 would have made `/var/lib/openbao/tls`
untraversable by the very CLI that needs the CA.

The second is that a Raft
snapshot cannot be written on the node at all, so snapshots are taken through stack's `openbao:tunnel`,
which is how the command is meant to be used — it is an API client, not a node-local tool. Anything that
makes an operator reach for `-tls-skip-verify` is a bug in this image, not an operator error.

**Configuration is a directory, and `user_data` is the last layer of it.** `-config` takes a directory
and may be given twice, so the service loads `/etc/openbao/config.d` then `/run/openbao/config.d`, and
`start_pre()` writes `user_data` into the second. Stanzas that may repeat — `listener`, `audit`,
`initialize` — append across files; everything else is last-wins, so a `user_data` fragment overrides the
node. Measured against 2.6.1: two `initialize` stanzas in two different directories both execute, in file
order. `/run` is tmpfs on purpose — a fragment in `/etc` would outlive the `user_data` that produced it
the moment `user_data` shrank, which is the kind of stale state that is invisible in a diff.

**Appending is why the image ships three fragments and not one.** `audit` and `listener` append, so a
user's fragment cannot switch off what the image declares — measured: an `audit` block in a second
fragment enables a *second* device, it does not replace the first. One combined file would therefore make
every default in it unremovable. Split by concern —  `00-storage.hcl`, `10-listener.hcl`, `20-audit.hcl` —
each can be overwritten or deleted on its own, and each says in its header whether it is structural
(coupled to `openbao-volume`, the AppArmor profile or the TLS gate) or a default. Do not recombine them.

**The image must ship no `seal` stanza.** Without one OpenBao uses Shamir, which needs no key material
present and is the right default for an image other people boot — and it fails closed, since an
uninitialized node serves nothing. Shipping one would make every node without a key file refuse to load,
turning the default case into a failure; it would rule out the transit and KMS seals, which have no key
file to give; and it would mandate the *weakest* at-rest option, because a static key lives on the disk it
decrypts while Shamir shares never touch the node. `verify-image` asserts the absence across the whole
directory.

**Omitting `tls_cert_file` turns ACME on; it does not turn TLS off.** OpenBao 2.6.1 enables ACME by
default when that parameter is empty, pointed at Let's Encrypt production, and its HTTP-01 challenge takes
a temporary bind on port 80 — measured, the server logs
`listener-acme.maintenance: started background certificate maintenance` and reports `tls: "enabled"` with
no certificate configured at all. That is a sensible default for a node on the public internet and the
wrong one for a node reached over a private address, which cannot complete the challenge and retries
indefinitely while everything else looks healthy. Since `10-listener.hcl` is a fragment a user is invited
to replace, this is a trap the image ships toward rather than away from: the fragment's header says so and
`openbao-selfcheck` reports which of the two is in effect. OpenBao offers HTTP-01 and TLS-ALPN-01 and no
DNS-01, so there is no challenge type that works without inbound reachability.

**A static seal key with a trailing newline is a fatal error that names neither the file nor the cause.**
`openssl rand -base64 32 > key` produces one, and OpenBao answers
`unknown encoding for AES-256 key: must be either a raw, hex, or base64-encoded`. Measured against 2.6.1.
`start_pre()` refuses to start and says how to fix it; `openbao-selfcheck` checks it too. Do not "fix"
this by trimming the file — silently rewriting an operator's key material is worse than refusing.

**TLS lives on the attached volume, the seal key does not, and the split is deliberate.**
`/var/lib/openbao/tls` reattaches with the volume, so replacing a Droplet needs no certificate copied back
and none reissued — the certificate is about OpenBao's *name*, not the node's address. The seal key stays
at `/etc/openbao/seal/key` on the boot disk, which is what keeps a snapshot of that volume useless on its
own: move it across and the ciphertext and its key sit on one disk. Raft moved to `data/` under the mount
so the mountpoint could be root-owned; `openbao-volume` refuses to start on a pre-2026-08-11 volume rather
than initializing an empty store beside the old one.

**The audit device does not rotate itself, and a full root filesystem is an outage.** Upstream is
explicit: the `file` device "does not currently assist with any log rotation", and a `SIGHUP` makes it
close and reopen. OpenBao refuses requests when every audit device fails to write, so an unbounded audit
log — 5.8 KiB per operation, measured — takes the store down with the disk. `crond` runs
`openbao-rotate-logs` every fifteen minutes for exactly this, and `rc-service openbao reload` is the
signal path it depends on. Do not remove either without replacing what it does.

## Applies to every change

- Every property this image claims must be asserted by something that fails loudly. Configuration is a
  claim; `scripts/verify-image` and `/usr/local/sbin/openbao-selfcheck` are where it becomes a fact.
  A rule nothing checks is a suggestion.
- The image is a security boundary for `stack`'s entire credential chain. Prefer removing a package to
  adding one, and say in `image/packages` why anything new is needed.
- Do not add a shell, an interpreter, or a package manager. `preStop`-style conveniences are not worth
  what they cost here, and `verify-image` will reject them.
- Keep runtime files ASCII-only. This is no longer only a habit: since the image loads `user_data` as a
  configuration fragment, that path is live, and DigitalOcean discards a whole document over one
  multi-byte character. `/etc/init.d/openbao` refuses to start on a non-ASCII fragment rather than
  letting it surface as a parse error pointing at a line that looks fine.
- Do not add a `Co-Authored-By` trailer, or any other tool-attribution trailer, to a commit.
- Bump `OPENBAO_IMAGE` and `BAO_SHA256` together, and keep them in step with
  `stack/infrastructure/platform/variables.tf`.
- **Remove packages by editing `image/packages` where you can, and by `purge` in `setup.sh` only where
  you cannot.** `apk` resolves a package set correctly and leaves its database honest; an `rm` leaves the
  database claiming files that are gone. `purge` is for the ones apk would refuse because they are hard
  dependencies of something needed — it deletes exactly the files apk recorded, symlinks included, and
  writes its own line into `/etc/openbao-appliance-packages`. Never hand-list paths: that is how
  `/bin/bbsuid` was deleted and took `mount` with it.
- **This image is published for other people to boot, so a default is not a decision you get to make for
  them.** Ship the safe default, make the alternative reachable without editing the image, and say what
  it costs where they will read it. `RAFT_DEVICE=none` and the configuration-driven TLS gate are both
  this shape: the accident stays impossible, the deliberate choice stays available.

## What is not settled

- Whether the AppArmor profile is tight enough for the last two uses. Unsealing, KV reads and writes,
  policy writes, AppRole, audit, leader election and a full restart now produce **zero** denials against
  the server. The database secrets engine loads in-process and reaches `connect()`, so the blanket exec
  denial is not the problem it looked like — but no credential has been minted against a real PostgreSQL
  instance, and Agent injection from a cluster has not been exercised.
- The kernel command line carries `lockdown=integrity` and `module.sig_enforce=1`, both boot-tested
  alone. It still carries no `mitigations=`. That can prevent boot; add it on its own, with a boot test.
- **It has run on a real Droplet**, as of 2026-08-11: boot to SSH in 6.5s, the Raft volume found through
  sysfs, OpenBao initialised, unsealed, served and rebooted with the store intact, and zero AppArmor
  denials. What the lab still does not reproduce is the timing — it is TCG, an order of magnitude out —
  so treat a boot measured there as useful only against another boot on the same host.
- **Both remaining paths are now exercised on real infrastructure.** A dynamic PostgreSQL credential was
  minted against a managed database and used to log in; a pod in a DOKS cluster authenticated through
  the Kubernetes auth method and read a secret, with the real Agent doing it from an init container.
  Zero AppArmor denials against the server across all of it.
