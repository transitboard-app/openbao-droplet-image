# openbao-droplet-image

The DigitalOcean custom image the Transitboard OpenBao Droplets boot: a single-purpose Alpine appliance
running OpenBao directly on the host.

It replaces a Debian Droplet that installed podman at first boot and ran OpenBao in a container. What it
buys is **attack surface**: 93 packages against about 210, no container runtime, no package manager, no
interpreter, no shell for the service account, no setuid binary, no SSH client, no bootloader installer,
no raw filesystem editor, and a kernel with the module tree and the initramfs cut down to what this
machine actually uses. OpenBao runs directly on the host under an AppArmor profile that grants no
capability of any kind — a stricter version of the `--read-only`, `--cap-drop ALL` and near-empty
filesystem podman was providing, because it constrains the process rather than the container around it.

It is **not** built so OpenBao can lock its memory. That was the original reason and it is dead: OpenBao
2.x has dropped mlock support outright, `disable_mlock = false` is a fatal configuration error, and a
Droplet with `CAP_IPC_LOCK` fully applied still showed `VmLck: 0`. What stands in its place is the
absence of swap, which is upstream's own advice — see `AGENTS.md`, which exists mostly to stop this
being reintroduced.

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

### `mise run boot` is emulated on a Mac, and that is not fixable

`boot` passes no `-accel`, so QEMU tries KVM and falls back to TCG, and prints which it got. On Apple
Silicon it will always say TCG, and no amount of configuration changes that:

- **Rosetta cannot help.** It translates x86-64 *user-space* binaries inside an ARM Linux VM. This
  artifact is a disk image with an x86-64 *kernel*, and a translator that works one process at a time
  has nothing to say about `vmlinuz`. The same goes for `binfmt_misc` and `qemu-user`.
- **`-accel hvf` is same-architecture only.** Apple's hypervisor virtualises ARM on ARM. There is no
  x86-64 hardware on the machine to virtualise, so an x86 guest must be emulated instruction by
  instruction.

So a boot timed on an Apple Silicon Mac is roughly an order of magnitude off, and only useful for
*comparing* two builds on the same host. For a wall-clock number that means something, use CI — the
`Check` workflow makes `/dev/kvm` usable and the boot test runs hardware-accelerated there — or boot the
published image on an actual Droplet.

On an x86-64 Linux host, `boot` uses KVM automatically as long as you can read `/dev/kvm`
(`sudo usermod -aG kvm "$USER"`, then log in again).

## Tasks

| Task | Platform | Does |
| --- | --- | --- |
| `deps` | linux-x64 | Checks the host tools and the kernel's ext4 support |
| `stage` | linux-x64 | Stages the overlay and mise's `bao`, asserting it is a linux-x64 ELF |
| `build` | linux-x64 | Builds `out/openbao-appliance.qcow2` |
| `verify` | linux-x64 | Mounts the image and asserts everything checkable without booting |
| `boot` | any + qemu | Boots under QEMU against a faked metadata service and Raft volume |
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

93 packages, against about 210 for the Debian-plus-podman node it replaces. `mise run verify` prints the
count on every build rather than leaving it to be quoted from memory.

Most of that reduction is not Alpine. It is dropping the container runtime (55 packages on its own) and
using `tiny-cloud` instead of `cloud-init` — 5 MiB against 62 MiB, because cloud-init brings a Python
runtime with it. `apparmor` then turned out to depend on Python anyway, so the build removes it after
installing: `apparmor_parser` is a C binary and the OpenRC service is plain shell, so nothing the
appliance runs needs an interpreter.

The rest is things that arrive as dependencies, do a job during the build, and have no caller on a
running node. Each is removed and recorded in `/etc/openbao-appliance-packages`:

| Removed | Why it was there | Why it is not needed |
| --- | --- | --- |
| the OpenSSH **client** suite | the `openssh` meta-package | every session is inbound; the tunnels are `ssh -L` from your machine |
| `tc`, `ss`, `bridge`, `genl`, `libxtables` | the `iproute2` meta-package | only `ip route replace` is called; `ip` is in `iproute2-minimal` |
| `syslinux`, `extlinux`, `mtools` | installing the bootloader | the bootloader is installed |
| `mkinitfs`, `nlplug-findfs`, `cryptsetup`, `device-mapper` | building the initramfs | the initramfs is built, and nothing here updates a kernel |
| `debugfs`, `badblocks`, `e2image` | `resize2fs` is in `e2fsprogs-extra` | a raw ext editor reads the Raft volume around its permissions |
| `libffi`, `libgdbm`, `libpanelw`, `libreadline`, `libexpat` | Python's closure | Python is gone; nothing links them |
| `libapk`, `/usr/share/apk` | apk | removing `/sbin/apk` and keeping the library that installs packages is half the job |

There is no package manager, no shell for the `openbao` user, no interpreter, no setuid binary, no SSH
client and no bootloader installer. `mise run verify` fails if any of those reappear.

Size is dominated by OpenBao itself: `bao` is 136 MiB stripped, of 185 MiB of content. Of the
remaining 49 MiB, 12 MiB is the kernel and 5 MiB the initramfs. Choosing a smaller distribution moves a number that
was never the constraint — the reason to build this is the attack surface, not the megabytes.

The kernel is cut the same way, and the two halves have to be cut together. `setup.sh` prunes
`/lib/modules` down to what a Droplet can present — virtio networking and storage, ext4, and nothing
else — and then **regenerates the initramfs**, because the initramfs is built when the kernel package is
installed and had been keeping a full copy of everything the prune removed. Modules are kept by
dependency closure rather than by name: `virtio_net` loads with `net_failover`, and an image that keeps
only the file named `virtio_net.ko` boots with no network at all.

## Checking

`Check` runs on every push and pull request: lint, build, offline verification, and the QEMU boot test —
the same tasks the release runs, on the same `ubuntu-24.04` host, minus the publishing. It also fails if
`mise.linux-x64.lock` is out of step with the config beside it, because a lockfile is only worth having
if it describes the artifact that was actually built.

Both build inputs are pinned by that lockfile: the version, the download URL and the checksum, for every
platform. `.miserc.toml` sets `locked = true`, so mise installs what the lockfile says rather than what
the registry offers today, and `locked_verify_provenance = true`, so a tool that publishes a build
attestation has it checked rather than merely its checksum. Refresh it with `mise lock` after changing a
version, and commit the result.

## Releasing

`Build and release the appliance image` is a manually triggered workflow — `workflow_dispatch` with the
tag as an input. It builds, verifies, boots, compresses, and creates a release with the `.qcow2.bz2`
attached, plus the sha256, the build manifest and the full package list in the notes.

It also **attests the artifact**. `actions/attest-build-provenance` records which repository, workflow
and commit produced the file, signed by GitHub's own identity, so anyone can check where a published
image came from without trusting the image:

```bash
gh attestation verify openbao-appliance.qcow2.bz2 --repo <owner>/<repo>
```

The image carries the same facts internally at `/etc/openbao-appliance-release` — commit, Alpine branch,
OpenBao version, build date — but that is the artifact describing itself. The attestation is the half a
stranger can rely on, which matters for an image offered for other people to boot.

It is manual on purpose: this image is the boot medium for the machine holding every production
credential, so it is released when someone decides to, not when a branch moves. Tags are CalVer
(`YYYY.MM.DD.N`), validated before the build runs, and the workflow refuses a tag that already exists.

**This repository is public, so a release asset is directly importable** — which is what makes the whole
publishing path a one-liner. DigitalOcean's importer performs an unauthenticated `GET` and no token
handshake, so this only holds while the repository stays public. If it is ever made private, release
assets become unreachable to the importer and the artifact has to go behind a pre-signed Spaces URL
instead. Nothing warns you: the import simply fails to fetch.

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
# From stack, where `mise run infra:apply` has already issued this material. The certificate is about
# OpenBao's NAME, not this node's address, which is why it can be issued before the node exists.
scp .openbao/tls/{server.crt,server.key,ca.crt} root@<node>:/var/lib/openbao/tls/
ssh root@<node> 'rc-service openbao start'
```

**That destination is on the attached volume, which is the point.** A replacement Droplet reattaches the
volume and the certificate is still there and still valid, so this is once per volume rather than once per
node. `openbao-volume` creates the directory at boot, so it exists before the first `scp`.

**Running without an attached volume** is supported and has to be asked for. A node that cannot find
exactly one DigitalOcean volume refuses to start, because OpenBao quietly writing its Raft store to the
boot disk while an attached volume sits empty is the one failure a secret store cannot absorb. Setting
`RAFT_DEVICE="none"` in `/etc/conf.d/openbao-volume` says you mean it, and cannot be reached by a volume
failing to attach. The store then does not survive the Droplet: take Droplet snapshots, and expect to
reinstall the TLS material on each new node.

All three files are required — `ca.crt` because the listener names it as `tls_client_ca_file` — and the
service applies `root:openbao` and the right modes to them itself on every start, so nothing here has to
get a `chown` right.

The **seal key** deliberately does not live there. If you are using the static seal it goes to
`/etc/openbao/seal/key` on the boot disk, and it is the one file a replacement node still needs: keeping
it off the volume is what makes a snapshot of that volume useless without it.

**If your node is publicly reachable, you can skip all of this and let OpenBao get its own certificate.**
Replace `10-listener.hcl` with one that omits `tls_cert_file` and sets `tls_acme_domains` and
`tls_acme_email`, and OpenBao requests a publicly-trusted certificate from Let's Encrypt — no `scp`, no
CA, and no `ca.crt` on any client. Note what that requires, because the failure mode is a retry loop
rather than an error: OpenBao offers HTTP-01 and TLS-ALPN-01 and **no DNS-01**, so the CA must be able to
reach the name, and HTTP-01 takes a temporary bind on port 80. A node on a private address cannot use it.
Transitboard's own deployment cannot, which is why the image ships file-based TLS as the default — but
that is a property of that deployment, not of this image. `openbao-selfcheck` reports which of the two is
in effect, and **an empty `tls_cert_file` selects ACME rather than disabling TLS**, so this is opted into
by editing rather than by deleting.

Every boot after that starts OpenBao on its own — which is a deliberate change from the Debian node,
whose unit was installed disabled so a reboot could not skip the TLS step. With one node and no quorum,
a secret store that stays down after an unattended reboot is the worse failure.

**The `bao` CLI on the node is already pointed at its own server.** `/etc/profile.d/openbao.sh` sets
`BAO_ADDR` to the address OpenBao advertises and `BAO_CACERT` to the CA the listener is configured with,
both read from the loaded fragments rather than hard-coded, so they stay right if you move the files or
use ACME. Without that, the first command anybody ran answered `x509: certificate signed by unknown
authority` and the obvious way out was `-tls-skip-verify` — which turns off certificate verification on
the machine holding every production credential. **You should never need that flag here; if you do, that
is a bug in this image.**

It is set for login shells, so an interactive `ssh root@<node>` has it and `ssh root@<node> 'bao status'`
does not — that runs a non-login shell. Use `ssh root@<node> 'sh -lc "bao status"'` for a one-off.

Then check the claims:

```bash
ssh root@<node> openbao-selfcheck
```

That asserts AppArmor is enforcing, OpenBao is confined, it holds no capabilities and runs as uid 65532,
`no_new_privs` is set, there is no swap, the Raft volume is mounted, and no AppArmor denial has been
recorded against the server. It is the difference between the image being configured correctly and the
node being correct. It also runs at the end of every boot, so its verdict is on the serial console
DigitalOcean's recovery console shows without anyone having to ask for it.

### Knowing when it is ready

**DigitalOcean has no readiness hook.** A Droplet is `active` in the API as soon as the hypervisor has
started it; there is no callback, no health gate, and nothing analogous to an ASG lifecycle hook. The
provider never learns that OpenBao is serving, and nothing in `/etc/init.d` can tell it — OpenRC reports
a service `started` the moment `supervise-daemon` has spawned the process, which here is true while the
node is still sealed and serving nothing.

The readiness signal is OpenBao's own, and it is an HTTP endpoint:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt https://<node>:8200/v1/sys/health
```

| Code | Means |
| --- | --- |
| 200 | initialized, unsealed, active — **ready** |
| 429 | unsealed but standby |
| 501 | not initialized |
| 503 | sealed |

Three ways to consume it, depending on what needs to know:

- **A DigitalOcean Load Balancer** in front of the Droplets is the closest thing to the provider knowing:
  its health check polls that path and it routes only to healthy nodes. Note it must trust the
  certificate, so a private CA means using a TCP check or a publicly-trusted certificate.
- **Terraform/OpenTofu** gating dependent resources on a poll of the same endpoint.
- **A human**, from `openbao-selfcheck` — which now prints `READY` or the reason it is not, at the end of
  every boot, onto the serial console DigitalOcean's recovery console shows. That is the one place you
  can see "sealed, waiting for you" without being able to log in first.

**With the default Shamir seal a node can never become ready on its own**, because unsealing needs a
human with key shares — so if what you want is a Droplet that boots straight into service, the lever is
auto-unseal (see [Sealing](#sealing)), not anything about boot speed.

### Configuring a node

The image reads two directories, so nothing here needs editing in place:

| Loaded | Holds | Written by |
| --- | --- | --- |
| `/etc/openbao/config.d/00-storage.hcl` | the Raft store — **structural** | the image |
| `/etc/openbao/config.d/10-listener.hcl` | the API listener and TLS paths — **structural** | the image |
| `/etc/openbao/config.d/20-audit.hcl` | the file audit device — a **default** | the image |
| `/etc/openbao/config.d/*.hcl` | anything else this node needs | you, over `scp` |
| `/run/openbao/config.d/50-user-data.hcl` | the same, from DigitalOcean `user_data` | the service, at every start |

`bao server -config=<dir>` loads every `.hcl` in a directory in alphabetical order, and the service passes
both directories with `/run` last.

**Overriding works for some settings and not others.** Settings that may appear once — `ui`, `storage`,
`default_lease_ttl` — are last-wins, so a later fragment replaces an earlier one. Stanzas that may repeat
— `listener`, `audit`, `initialize` — are **appended**. A second `audit` block does not replace the one
the image ships; it enables a second device alongside it. So a fragment of yours cannot switch off what
this directory already declares: to replace one of the image's defaults, overwrite or delete that file.
That is why they are three files named by concern rather than one.

The two marked **structural** are coupled to the rest of the image — `00-storage.hcl` to the
`openbao-volume` service that mounts the attached volume there and to the AppArmor profile that grants
writes on exactly that path. Change it and those stop applying. `20-audit.hcl` is a plain default:
delete it, or replace it to send audit elsewhere. It ships enabled because OpenBao 2.x cannot enable an
audit device through the API at all, so a node without one has no way to gain one without a restart.

**The service will not start until the certificate your listener names is actually there** — but it
gates on *your* configuration, not on the paths the image happens to ship. Replace `10-listener.hcl`
with an ACME listener, or one with `tls_disable = true` behind a proxy that terminates TLS, or one
pointing somewhere else entirely, and the node starts. Name a file that is not there and it refuses and
tells you which file, which is the point of the gate and is unchanged. `user_data` is read into the
configuration before the gate runs, so a listener supplied that way counts.

`user_data` must begin with the line `#openbao-config`. Without it the document is ignored rather than
loaded, so a Droplet created with `user_data` meant for something else does not end up with a secret store
that refuses to start. It must also be ASCII: DigitalOcean does not deliver `user_data` as UTF-8, and one
multi-byte character — an em-dash in a comment is the way this actually happens — corrupts the whole
document. The service checks both and says which one failed.

**`user_data` is root-equivalent on this node**: a fragment can add a `seal` stanza, an `initialize`
stanza or a second `listener`, which is the whole point of it. Two things follow. Any process on the
Droplet can read it back from the metadata service at `169.254.169.254`, so it is not a private channel
to the server. And if you create Droplets with Terraform or OpenTofu, `user_data` is an ordinary
attribute that is stored in state — the DigitalOcean provider offers no write-only variant, checked
against the installed provider schema — so anything you put there is in your state file too.

DigitalOcean's Droplet API does **not** return `user_data` on retrieve, so a plain API token does not read
it back; that has been [asked for and not shipped](https://github.com/digitalocean/api-v2/issues/121).
Treat it as configuration that is visible to your state file and to the node, and keep key material out
of it on those grounds rather than on the provider's.

### Sealing

By default a node uses **Shamir shares**: `bao operator init` once, and three of five shares to unseal
after every restart. That needs no key material on the node and no decision made in advance, which is why
the image ships no `seal` stanza at all.

For unattended boot, the built-in option that needs no external KMS is the **static seal**. Install a
32-byte key and add a fragment naming it:

```bash
# On a machine you trust -- NOT on the node, and keep a copy in your password manager
openssl rand -base64 32 | tr -d '\n' > seal-key
scp seal-key root@<node>:/etc/openbao/seal/key
```

```hcl
# /etc/openbao/config.d/10-seal.hcl, or the same lines in user_data
seal "static" {
  current_key_id = "<any name>"
  current_key    = "file:///etc/openbao/seal/key"
}
```

The `file://` reference is what keeps the fragment identical on every node: only the file's contents
differ. The service applies `root:openbao 0640` to the key itself, so the `scp` above cannot get it wrong.

**Write the key without a trailing newline.** `openssl rand -base64 32 > seal-key` produces one, and
OpenBao rejects it with `unknown encoding for AES-256 key`, naming neither the file nor the cause. The
`tr -d '\n'` above is the fix; the service refuses to start rather than let you discover it from that
message, and `openbao-selfcheck` checks it too.

Understand what this trades before choosing it. The key decrypts the Raft store and lives on the same
Droplet, so a snapshot of the whole host carries both — where Shamir shares kept off the machine mean a
stolen disk is useless. It does **not** weaken anything against an attacker with root on a running node,
who already reaches unsealed material in memory. And it does not remove custody: the key still has to be
somewhere safe, because restoring a snapshot onto a new node needs it.

Two consequences of auto-unseal worth knowing before you turn it on. It is what makes OpenBao's
[self-initialization](https://openbao.org/docs/configuration/self-init/) usable, so a node can come up
fully configured with no `bao operator init` at all — and self-init generates **no recovery keys** and
revokes the root token after use. If you take that path, make sure the credential self-init creates is one
you can keep, and generate recovery keys with `sys/rotate/recovery/init` once you can authenticate.

### Operator commands run under the AppArmor profile

A profile attaches to a path, so `profile openbao /usr/sbin/bao` confines **every** execution of that
binary — including the one you type. That is mostly invisible, because the profile grants what the CLI
needs, but two things follow from it and neither is a bug:

- `openbao-selfcheck` reports denials from your own CLI as a separate, non-failing line. Only denials
  against the running server are a failure.
- The CLI cannot write to `/root` or `/tmp`, so **a Raft snapshot cannot be saved on the node**, and the
  attempt fails with a permission error that reads like a fault. Take snapshots off the node instead,
  which is how the command is meant to be used — it is an API client, not a node-local tool:

  ```bash
  # From stack. The CLI runs unconfined on your own machine; only TLS-wrapped API traffic crosses.
  mise run openbao:tunnel -- bao operator raft snapshot save openbao-$(date +%F).snap
  ```

  This also keeps the `sudo`-capable token on the operator's machine rather than putting it on the node,
  which is the reason the tunnel exists. See `documentation/openbao-operations.md` in stack for retention
  and restore testing.

### Files you give OpenBao must live under `/etc/openbao`

The AppArmor profile attaches to `/usr/sbin/bao`, so it confines the CLI you type as well as the
server, and it grants no read on `/tmp` or `/root`. Anything you hand to `bao write ... @file` —
a database CA, a Kubernetes CA, a token-reviewer JWT — has to be somewhere the profile allows:

```bash
install -d -o root -g openbao -m 0750 /etc/openbao/kubernetes
install -o root -g openbao -m 0640 ca.crt /etc/openbao/kubernetes/ca.crt
```

`scp` it to `/tmp` first and the write fails with `permission denied` on a file that is plainly there,
which reads as a bug and is the profile doing its job. It is the same shape as a Raft snapshot not being
writable on the node.

### Databases: DigitalOcean signs managed clusters with a private CA

The image ships `ca-certificates`, and it does **not** verify a DigitalOcean managed database. Those
carry a per-project CA (`CN=<project-uuid> Project CA`), so `sslmode=verify-full` against the public
bundle fails with `x509: certificate signed by unknown authority` — measured against a real managed
PostgreSQL 17. Install the project CA and name it:

```bash
doctl databases get-ca <database-id> | sed -n '/BEGIN/,/END/p' > postgres-ca.crt
scp postgres-ca.crt root@<node>:/etc/openbao/postgres-ca.crt
ssh root@<node> 'chown root:openbao /etc/openbao/postgres-ca.crt && chmod 0640 /etc/openbao/postgres-ca.crt'
```

```bash
bao write database/config/pg plugin_name=postgresql-database-plugin allowed_roles=app \
  connection_url='postgresql://{{username}}:{{password}}@HOST:25060/defaultdb?sslmode=verify-full&sslrootcert=/etc/openbao/postgres-ca.crt' \
  username=doadmin password=...
```

Do not reach for `sslmode=require` to make the error go away: it encrypts and verifies nothing, on the
connection that mints your database credentials.

### Logs

`audit.log`, `stdout.log` and `stderr.log` live in `/var/log/openbao` on the Droplet's own disk, not on
the Raft volume, because OpenBao refuses requests when every audit device fails to write and an audit log
that filled the Raft volume would take the store down.

They are bounded by `/usr/local/sbin/openbao-rotate-logs`, run every fifteen minutes by `crond`: 640 MiB
of audit history and 64 MiB of operational log, so the logs cannot occupy more than about 3% of the
smallest Droplet. The audit log is renamed and OpenBao is sent a `SIGHUP` to reopen it, which is
upstream's documented protocol — the file audit device does not rotate itself. At the measured 5.8 KiB
per operation that is a bit under a fortnight of audit records on the node; anything longer belongs in a
store off the node.

## Status

**Builds, verifies and boots — on linux-x64, natively, in about 20 seconds.** Exercised end to end on an
`ubuntu` OrbStack amd64 machine: `mise bootstrap packages apply` → `build` → `verify` → `boot`.

`mise.linux-x64.toml` was selected by `auto_env` with no `MISE_ENV` set, `[tools]` supplied
`OpenBao v2.6.1` as a verified x86-64 ELF, and `[bootstrap.packages]` installed the apt set and skipped
the apk entries.

Under QEMU in legacy BIOS mode:

```
Kernel is locked down from command line; see man kernel_lockdown.7
LSM: initializing lsm=lockdown,capability,landlock,yama,apparmor
AppArmor: AppArmor initialized
 * Loading AppArmor profiles ... [ ok ]
   ++ expand_root: starting / done
 * The listener names TLS material that is not there:
 *     /var/lib/openbao/tls/server.crt
 * openbao-selfcheck: all checks passed
```

AppArmor is in the *active* LSM stack, not merely compiled in. The TLS gate refuses to start OpenBao and
names the file it wanted, which is the intended first-boot state — and the self-check says so rather than
reporting it as a fault. Root expansion is tiny-cloud's, measured: a 1 GiB image on a 5 GiB disk ends
with a 5118 MiB root filesystem.

93 packages, 0 setuid/setgid binaries, no interpreter, no package manager, no SSH client, no dangling
symlinks, 293 kernel modules in 6.4 MiB and a 5.4 MiB initramfs holding 20. **185 MiB of content**,
**82 MiB compressed**. 166 offline checks.

The qcow2 file is larger than the content and by a host-dependent amount: 219 MiB built on
`ubuntu-24.04` with qemu-img 8.2, 201 MiB built with qemu-img 10.2, from byte-identical filesystems —
`build:compact` drops zero clusters and newer qemu-img finds more of them. Quote the content size or the
compressed one; the qcow2 size is a property of the builder.

**OpenBao has been run through this image.** Against a faked DigitalOcean environment — a SCSI disk
presenting as vendor `DO` model `Volume`, a metadata service on `169.254.169.254`, and two interfaces —
the appliance mounted its Raft volume through sysfs, read its private address, unsealed, served KV v2
reads and writes, wrote a policy, enabled AppRole, wrote audit records, rotated its audit log, survived a
reboot with the store intact, and produced **zero AppArmor denials against the server** across all of it.
`scp` of the TLS material, `bao status` with no environment set by hand, and `ip route replace` were all
exercised on the same node. `documentation/` holds the audits that established this.

### On a real Droplet

**It has now run on DigitalOcean.** A `s-1vcpu-1gb` in `lon1`, built from the published
`2026.08.11.6` release asset imported with `mise run import`, with a 1 GiB volume attached:

| | |
| --- | --- |
| boot to SSH | **6.5s** first boot, **7.2s** rebooting with a live Raft store |
| kernel done | 2.3s; root mounted 2.8s; last kernel message 5.3s |
| `crng init done` | **0.04s** |
| root filesystem | 1 GiB image grown to 24.6 GiB |
| interfaces | `eth0` public, `eth1` VPC — the two-NIC arrangement is real |
| Raft volume | found through sysfs as `/dev/sda` and mounted |
| AppArmor denials | **0**, across install, init, unseal, traffic and a reboot |

OpenBao was initialised, unsealed, served KV v2 reads and writes, took a policy and an AppRole, wrote
audit records, survived a reboot with the store intact, and answered `GET /v1/sys/health` with **200**
from the public internet. `bao status` worked over SSH with no environment set by hand and no
`-tls-skip-verify`, against the private address DigitalOcean's own metadata service reported.

**The boot is not slow — 6.5 seconds.** Every larger number in this repository's history was emulation:
`mise run boot` on an Apple Silicon Mac is TCG, and CI was TCG too until `/dev/kvm` was made usable.
Note especially `crng init done` at 0.04s: DigitalOcean presents no `virtio-rng` device, and entropy is
still immediate, so the 13.9-second entropy stall that the QEMU boot test used to suffer is an artifact
of the lab and not something a Droplet pays.

### Still unsettled
- ~~No credential minted against a real PostgreSQL~~ — **done.** A managed PostgreSQL 17, the database
  secrets engine configured with `verify-full` against DigitalOcean's project CA, a dynamic credential
  minted with an hour lease, and that credential used to log in and query. Zero AppArmor denials.
- ~~Agent injection and pod routes unexercised~~ — **done.** A DOKS cluster in the same VPC: a pod could
  not reach OpenBao at all (`HTTP 000`) until `openbao-pod-routes` installed
  `10.107.0.0/25 via <node>`, after which it answered `HTTP 200`. The real OpenBao Agent then ran as an
  init container — which is exactly what the injector injects — authenticated with its service account,
  templated the secret to a shared volume, and the application container read it. A denied path
  correctly returned 403.
- `mitigations=auto,nosmt` is still not on the kernel command line. It can prevent boot and has not been
  tested here; add it on its own, with a boot test.
- **There is no way to log in at the console, by construction.** Root's password field is `*`, there is
  no getty on any virtual terminal, and the `debug` build that used to bake in a password has been
  removed. DigitalOcean's console still shows the whole boot including the self-check verdict, which is
  what it is actually useful for. If SSH breaks, recovery is DigitalOcean's recovery ISO — it boots a
  rescue system with this disk attached and needs nothing baked into the image — or rebuilding the node
  and reattaching the Raft volume. That is a decision, not an accident, and it is worth re-reading before
  the first real incident.
- **Cutting `drivers/net` to virtio is a bet that DigitalOcean's network presentation does not change** —
  and it is the opposite of the bet made about storage, where `drivers/nvme/host` is deliberately kept
  against exactly that possibility. Both are argued in `image/setup.sh`; only one of them can be right if
  the presentation ever moves. The boot test is what makes the network side safe to hold.

`AGENTS.md` has the rest.
