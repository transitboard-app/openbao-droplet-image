# The Raft store.
#
# This is the first of the fragments the image ships, and the first file anyone opens, so the directory's
# own rules are here rather than spread across all three.
#
#   /etc/openbao/config.d/*.hcl              the image's fragments, and anything you install beside them
#   /run/openbao/config.d/50-user-data.hcl   written from DigitalOcean user_data at every start
#
# `bao server -config=<dir>` loads every .hcl in a directory alphabetically, and the service passes both
# directories with /run last.
#
# **Overriding works for some stanzas and not others, and the difference is not obvious.** Settings that
# may appear only once -- `ui`, `default_lease_ttl`, `storage` -- are last-wins, so a later fragment
# replaces an earlier one. Stanzas that may repeat -- `listener`, `audit`, `initialize` -- are APPENDED.
# Measured against 2.6.1: an `audit` block in a second fragment does not replace the one below, it enables
# a second device alongside it.
#
# So a fragment cannot switch off what this directory already declares. Replacing one of the image's
# defaults means overwriting or deleting that file on the node -- which is why they are three files
# named by concern rather than one, and why each says whether it is structural or a default.
#
# **Structural.** The image's `openbao-volume` service finds the attached volume by SCSI vendor and model
# and mounts it at /var/lib/openbao, and the AppArmor profile grants `rwk` on exactly that path. Point
# storage somewhere else and both stop applying.
#
# **There is deliberately no `seal` stanza in this directory.** With none, OpenBao uses Shamir, which
# needs no key material on the node and no decision made when the image is built -- the right default for
# an image other people boot, and one that fails closed: an uninitialized node serves nothing at all. A
# `seal "static"` shipped here would make every node without a key file refuse to load, turning the
# default case into a failure, and would rule out the transit and KMS seals that have no key file to give.
# Auto-unseal is opted into with a fragment; README.md has the shape and the trade.

storage "raft" {
  path = "/var/lib/openbao"

  # **`node_id` is deliberately absent, which is not the same as unset.** OpenBao generates one on first
  # use and persists it to `/var/lib/openbao/node-id` -- measured against 2.6.1 -- so it is stable across
  # restarts and, because that file is on the Raft volume, it follows the store rather than the Droplet.
  # A node replaced for an image bump reattaches the volume and keeps its raft identity.
  #
  # This shipped as `node_id = "openbao-1"`, which was correct for one node and wrong for any more: every
  # node booting this image would have claimed the same raft identity. Letting OpenBao assign it makes
  # each node unique without anything having to know how many there are. Override with
  # `BAO_RAFT_NODE_ID` in /etc/conf.d/openbao if a specific value is ever needed; it wins over this
  # stanza and needs no fragment.

  # No `retry_join`, and the shape it should take when there is one is worth writing down here because
  # the obvious shape does not work.
  #
  # **Listing peer addresses in user_data is a dependency cycle**: the root that creates the Droplets
  # would be writing each Droplet's user_data from the Droplets' own private addresses. So the peers
  # cannot be templated in by the thing that knows them.
  #
  # What does work is discovery. This binary carries go-discover with a DigitalOcean provider, so a
  # fragment can say:
  #
  #   retry_join {
  #     auto_join        = "provider=digitalocean region=<region> tag_name=<tag> api_token=<token>"
  #     auto_join_scheme = "https"
  #     auto_join_port   = 8200
  #   }
  #
  # The tag already exists -- `infrastructure/platform/` creates one for the OpenBao Droplets and the
  # firewall matches on it -- so peers are found by asking DigitalOcean rather than by anyone keeping a
  # list. The cost is a read-only DigitalOcean API token ON the node, which is a new credential on the
  # machine that holds every other one, and it is the reason this is not enabled by default.
  #
  # D9 requires three nodes before production approval. With one there is no quorum, so the daily Raft
  # snapshot is the entire availability story rather than a background chore.
}

# There is deliberately no `disable_mlock` anywhere in this directory, and the line must not come back in
# either direction.
#
# OpenBao 2.x has dropped mlock support outright. `disable_mlock = false` is not a no-op but a fatal
# configuration error -- the server refuses to load and supervise-daemon respawns it to exhaustion:
#
#   error loading configuration from /etc/openbao/config.d: OpenBao has dropped support for mlock.
#   Please remove the line "disable_mlock" = false from your config and disable or encrypt swap instead.
#
# `disable_mlock = true` is tolerated, which is why the Debian nodes carried it without complaint, but
# it now describes a setting that does nothing. Absent is the only honest spelling, so absent it is.
#
# What replaces it is the absence of swap, which is upstream's own guidance. image/setup.sh configures
# none and strips any fstab entry; openbao-selfcheck asserts /proc/swaps is empty on every run.

# `ui` is deliberately unset, which means off. It is the one setting here that is pure preference rather
# than something the appliance needs, and an appliance that ships no shell should not serve a web
# console nobody asked for. Turn it on with `ui = true` in a fragment of your own; unlike the stanzas
# below, this one is last-wins, so a fragment really does override it.
