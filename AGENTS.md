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

## The three things most likely to be got wrong

**AppArmor is compiled in but not enabled by default.** `linux-virt` sets
`CONFIG_SECURITY_APPARMOR=y` and ships
`CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity"` — apparmor is absent from the active
stack. Without `lsm=...,apparmor apparmor=1` on the kernel command line, `apparmor_parser` loads the
profile without complaint, `aa-status` reports nothing, and OpenBao runs unconfined. It fails open and
it fails silently. `image/setup.sh` sets it and asserts it reached `/boot/extlinux.conf`;
`scripts/verify-image` asserts it again offline; `openbao-selfcheck` asserts the running process is
genuinely confined. Do not remove any of the three.

**Ambient capabilities, never `setcap`.** OpenBao gets `CAP_IPC_LOCK` from
`capabilities="^cap_ipc_lock"` in its init script, which supervise-daemon applies as an *ambient*
capability. A file capability would be the obvious alternative and is wrong twice over: it would modify
a binary that is otherwise byte-identical to the digest-pinned one upstream published, and file
capabilities are ignored under `no_new_privs`, so setting both would produce a process holding neither
— with no error to say so.

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

- Whether the AppArmor profile is tight enough or too tight. It has not yet run against a real workload.
  `openbao-selfcheck` reports denials since boot; that output is the input to the next revision.
- The kernel command line carries no `lockdown=` and no `mitigations=` yet. Each can prevent boot, and
  the image is not yet proven to boot at all. Add them one at a time, with a boot test each.
