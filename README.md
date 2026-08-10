# openbao-droplet-image

The DigitalOcean custom image the Transitboard OpenBao Droplets boot: a single-purpose Alpine appliance
running OpenBao directly on the host.

It replaces a Debian Droplet that installed podman at first boot and ran OpenBao in a container. What
that arrangement could not do, and this one can, is let OpenBao **lock its memory** — the container's
distroless binary ran as a non-root user with no `cap_ipc_lock`, so `disable_mlock = true` was
mandatory and swap had to be disabled as a stand-in. Here the capability is granted ambiently and
`openbao-selfcheck` proves the pages are locked.

## Quick start

On linux-x64 — ubuntu-24.04 is what CI uses and needs nothing else:

```bash
mise bootstrap packages apply && mise run build && mise run verify && mise run boot
```

The build is assembled on linux-x64 and nowhere else: it mounts an ext4 filesystem and chroots into it,
so it needs a Linux kernel with ext4 and root. The host does **not** need to be Alpine —
`alpine-make-vm-image` installs host packages only when it detects one, and everywhere else downloads
checksum-verified static apk-tools instead.

`mise.linux-x64.toml` is the only configuration — there is no `mise.toml`. mise selects it by platform
because `.miserc.toml` here sets `auto_env = true`. On macOS this directory has no tasks at all, rather
than tasks that exist and fail.

No x64 Linux to hand? On an Apple Silicon Mac with OrbStack:

```bash
orb create -a amd64 ubuntu build-x64
orb run -m build-x64 sudo modprobe ext4   # OrbStack ships ext4 unloaded; not needed on ubuntu-24.04
```

Build from a path on the machine's own filesystem rather than the shared `/mnt/mac` mount — loop devices
and chroots do not work over virtiofs.

## Tasks

| Task | Platform | Does |
| --- | --- | --- |
| `deps` | linux-x64 | Checks the host tools and the kernel's ext4 support |
| `stage` | linux-x64 | Stages the overlay and mise's `bao`, asserting it is a linux-x64 ELF |
| `build` | linux-x64 | Builds `out/openbao-appliance.qcow2` |
| `verify` | linux-x64 | Mounts the image and asserts everything checkable without booting |
| `boot` | any + qemu | Boots under QEMU on a serial console, legacy BIOS as DigitalOcean does |
| `compress` | any | bzip2, which DigitalOcean accepts and which suits a mostly-Go image |
| `import <url>` | any | Registers a published URL as a DigitalOcean custom image |
| `compare-upstream` | any + docker | Checks mise's `bao` against the binary in stack's pinned image |
| `lint` | any | shellcheck over the shell the image actually ships |

Both build inputs come from `[tools]`, so there is no fetching code in this repository at all:

- `github:openbao/openbao = "2.6.1"` — the same pin stack uses. `stage` copies mise's linux-x64 binary
  straight into the image, replacing a Docker pull, a container export and a tar extraction.
- `http:alpine-make-vm-image` — a bare shell script rather than a release artifact, which the `http`
  backend handles natively with `checksum` and `size`. mise refuses to install on a mismatch (verified by
  poisoning it), which is the entire supply-chain control for a script that runs as root with
  block-device access.

The build needs **root** — it mounts, chroots, attaches loop devices and chowns to uid 65532, none of
which has an unprivileged path. `sudo` is the right call and GitHub-hosted runners have passwordless
sudo, so CI needs nothing special. Note the task resolves `command -v alpine-make-vm-image` before
elevating, because sudo resets `PATH` and would not otherwise see a mise-managed tool.

## What is in the image, and what is not

104 packages, against about 210 for the Debian-plus-podman node it replaces. `mise run verify` prints
the count on every build rather than leaving it to be quoted from memory.

Most of that reduction is not Alpine. It is dropping the container runtime (55 packages on its own) and
using `tiny-cloud` instead of `cloud-init` — 5 MiB against 62 MiB, because cloud-init brings a Python
runtime with it. `apparmor` then turned out to depend on Python anyway, so the build removes it after
installing: `apparmor_parser` is a C binary and the OpenRC service is plain shell, so nothing the
appliance runs needs an interpreter.

There is no package manager, no shell for the `openbao` user, no interpreter, and no setuid binary.
`mise run verify` fails if any of those reappear.

Size is dominated by OpenBao itself: `bao` is 186 MiB of a roughly 290 MiB uncompressed image. Choosing
a smaller distribution moves a number that was never the constraint — the reason to build this is the
attack surface and the mlock, not the megabytes.

## Releasing

`Build and release the appliance image` is a manually triggered workflow — `workflow_dispatch` with the
tag as an input. It builds, verifies, boots, compresses, and creates a release with the `.qcow2.bz2`
attached, plus the sha256 and the full package list in the notes.

It is manual on purpose: this image is the boot medium for the machine holding every production
credential, so it is released when someone decides to, not when a branch moves. Tags are CalVer
(`YYYY.MM.DD.N`), validated before the build runs, and the workflow refuses a tag that already exists.

**While this repository is private, the release asset is not a usable import source.** DigitalOcean's
importer performs an unauthenticated `GET` and no token handshake, so a private repository's assets are
unreachable to it. Either make the repository public before publishing an image, or put the artifact
behind a pre-signed Spaces URL and pass that to `mise run import`.

## Publishing

DigitalOcean's `doctl compute image create` takes **only** `--image-url`. There is no file upload in the
API, so the compressed image has to sit somewhere DigitalOcean's fetcher can reach with an
unauthenticated `GET` before `mise run import` can register it. A GitHub release asset on a public
repository is the simplest such place; a pre-signed Spaces URL also works and keeps the artifact
private.

Publishing it as an OCI artifact does not work, and it was the original plan: registry blobs need a
token handshake even when the repository is public, and DigitalOcean's importer does not perform one.

Custom images bill at $0.06/GiB/month and nothing prunes old ones.

## Operating a node built from it

First boot comes up with OpenBao **not running**, by design: the service refuses to start until TLS
material is in place. Install it, then start:

```bash
# From stack, against the new node's private address
scripts/generate-openbao-tls <node-private-address>
scp .openbao/tls/{server.crt,server.key,ca.crt} root@<node>:/etc/openbao/tls/
ssh root@<node> 'chown 65532:65532 /etc/openbao/tls/* && rc-service openbao start'
```

Every boot after that starts OpenBao on its own — which is a deliberate change from the Debian node,
whose unit was installed disabled so a reboot could not skip the TLS step. With one node and no quorum,
a secret store that stays down after an unattended reboot is the worse failure.

Then check the claims:

```bash
ssh root@<node> openbao-selfcheck
```

That asserts AppArmor is enforcing, OpenBao is confined, `VmLck` is non-zero, `CAP_IPC_LOCK` is held,
`no_new_privs` is set, the Raft volume is mounted, and no AppArmor denials have been recorded. It is
the difference between the image being configured correctly and the node being correct.

## Status

**Builds, verifies and boots — on linux-x64, natively, in about 20 seconds.** Exercised end to end on an
`ubuntu` OrbStack amd64 machine: `mise bootstrap packages apply` → `build` → `verify` → `boot`.

`mise.linux-x64.toml` was selected by `auto_env` with no `MISE_ENV` set, `[tools]` supplied
`OpenBao v2.6.1` as a verified x86-64 ELF, and `[bootstrap.packages]` installed the apt set and skipped
the apk entries.

Under QEMU in legacy BIOS mode:

```
LSM: initializing lsm=lockdown,capability,landlock,yama,apparmor
AppArmor: AppArmor initialized
 * Loading AppArmor profiles ... [ ok ]
   ++ expand_root: starting / done
 * No TLS material in /etc/openbao/tls.
 * Starting sshd ... [ ok ]
```

AppArmor is in the *active* LSM stack, not merely compiled in. The TLS gate refuses to start OpenBao and
says how to fix it, which is the intended first-boot state. Root expansion is tiny-cloud's, measured: a
1 GiB image on a 5 GiB disk ends with a 5118 MiB root filesystem.

104 packages, 0 setuid/setgid binaries, no interpreter, no package manager, no dangling symlinks.
336 MiB qcow2, **148 MiB compressed**.

### Still unsettled

- **Never booted on a real Droplet.** DigitalOcean's own BIOS boot, metadata service and volume
  attachment are all unproven.
- **Networking has never come up.** Under QEMU the `networking` service fails for everything but `lo`,
  because there is no DigitalOcean metadata for tiny-cloud to configure an interface from. That is
  expected in the test environment and is exactly the thing that would make a real node unreachable, so
  it proves nothing either way.
- **OpenBao has never run**, because that needs TLS material. `VmLck`, `CAP_IPC_LOCK` and process
  confinement are asserted by `openbao-selfcheck` and none has been observed true.
- Root's password is locked, so DigitalOcean's recovery console cannot be used to log in. For an
  appliance that is replaced rather than repaired that is arguably right, but it is a decision — if SSH
  breaks, the node is rebuilt and the Raft volume reattached.

`AGENTS.md` has the rest.
