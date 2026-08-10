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
| `.github/workflows/` | the manual release pipeline |

## The things most likely to be got wrong

Every one of these was got wrong here first, and three of the four looked correct until the image ran on
a real Droplet. Local verification cannot reach them.

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

- Whether the AppArmor profile is tight enough. It has now run against a real OpenBao serving on a
  Droplet, which produced exactly one denial — `@{PROC}/@{pid}/mountinfo`, since granted — but that node
  was sealed the whole time. Unsealing, PostgreSQL credential minting and Agent injection have not
  exercised it yet. `openbao-selfcheck` reports denials since boot; that output is the next revision.
- The kernel command line carries no `lockdown=` and no `mitigations=` yet. Each can prevent boot. Add
  them one at a time, with a boot test each.
- Nothing has read from OpenBao through this image yet. It boots, mounts its Raft volume, loads an
  existing store and serves TLS on 8200; it has never been unsealed, so no client has completed a
  request against it.
