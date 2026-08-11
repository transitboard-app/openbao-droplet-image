# The audit device.
#
# **A default rather than structural** -- this is the fragment most likely to be wrong for someone else,
# and it is a separate file so it can be replaced. Delete it for no audit device at all, or overwrite it
# to send audit elsewhere. Adding a second fragment does NOT replace this one: `audit` appends, so you
# would get two devices writing two logs. Measured against 2.6.1.
#
# It ships enabled anyway, and the reason is not taste. OpenBao 2.x removed API-based audit device
# management outright -- PUT /v1/sys/audit/file answers "cannot enable audit device via API; use
# declarative, config-based audit device management instead" -- so an operator who forgets this file has
# no way to add one later without a restart, and no audit trail in the meantime. Declaring it is also
# strictly better than enabling it after unsealing would have been: the device exists from the first
# request, so the record covers initialization and unsealing rather than beginning after them.
#
# All three fields are required; the block label alone is not the path.
#
# /var/log/openbao is on the Droplet's own disk, not the Raft volume, because OpenBao refuses requests
# when every audit device fails to write -- an audit log growing into a full Raft volume would take the
# service down. Nothing rotates it but `openbao-rotate-logs`, which crond runs every fifteen minutes and
# which signals this device to reopen its file; a replacement that writes elsewhere needs its own answer
# to that, or the disk fills and the store stops serving.

audit "file" {
  type = "file"
  path = "file/"
  options = {
    file_path = "/var/log/openbao/audit.log"
  }
}
