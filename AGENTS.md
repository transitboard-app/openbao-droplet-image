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
Confinement comes from the whitelist, not from blanket denials. Only `deny /** x` is safe, because
nothing is granted exec anywhere.

**A dependency cannot be declared on the metadata service, so exactly one service waits for it.**
`need net` means an interface is configured. It cannot mean "the hypervisor is answering HTTP on
`169.254.169.254`", because that endpoint is not a service on this machine and OpenRC has no handle on
it — and DHCP completing does not imply the metadata service is serving. So the wait is a retry loop, and
it lives in `/etc/init.d/metadata`, which caches what it reads to `/run/metadata` and `provide`s a
virtual. `cloud-ssh-keys` and `openbao` declare `need metadata` and read files; neither contains a URL.
Do not give a consumer its own fetch. That is what was here before, and the two copies diverged — one
retried fifteen times, the other tried once and produced a node that answered on port 22 with no secret
store. Assert the wait once, or it will be got wrong twice.

**The AppArmor profile confines the CLI as well as the server, because a profile attaches to a path.**
`profile openbao /usr/sbin/bao` covers every execution of that binary, including the one an operator
types. This is not a mistake to fix by adding a second unconfined path — it is a property to design
around, and two things follow from it. `/etc/openbao/tls` is `root:openbao 0750` rather than
`65532:65532 0700` precisely so a confined root can read the CA without a capability; owning the
directory by uid also meant OpenBao could rewrite its own private key, which it now cannot. And a Raft
snapshot cannot be written on the node at all, so snapshots are taken through stack's `openbao:tunnel`,
which is how the command is meant to be used — it is an API client, not a node-local tool. Anything that
makes an operator reach for `-tls-skip-verify` is a bug in this image, not an operator error.

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
- Keep runtime files ASCII-only. They do not travel through DigitalOcean's `user_data` path today, but
  the habit is cheap and that path discards a whole document over one multi-byte character.
- Do not add a `Co-Authored-By` trailer, or any other tool-attribution trailer, to a commit.
- Bump `OPENBAO_IMAGE` and `BAO_SHA256` together, and keep them in step with
  `stack/infrastructure/platform/variables.tf`.

## What is not settled

- Whether the AppArmor profile is tight enough for the last two uses. Unsealing, KV reads and writes,
  policy writes, AppRole, audit, leader election and a full restart now produce **zero** denials against
  the server. The database secrets engine loads in-process and reaches `connect()`, so the blanket exec
  denial is not the problem it looked like — but no credential has been minted against a real PostgreSQL
  instance, and Agent injection from a cluster has not been exercised.
- The kernel command line carries `lockdown=integrity` and `module.sig_enforce=1`, both boot-tested
  alone. It still carries no `mitigations=`. That can prevent boot; add it on its own, with a boot test.
- Nothing has run on a real Droplet since the appliance was rewritten. The lab imitates DigitalOcean's
  volume presentation, metadata service and two-NIC arrangement, and is not a substitute for any of them.
