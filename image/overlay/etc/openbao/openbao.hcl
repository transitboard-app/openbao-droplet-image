ui = true

# api_addr and cluster_addr are deliberately absent. Each has to be this node's own private address,
# which is not known when this image is built -- an image predates every Droplet that will boot it. The
# init script reads the address from the metadata service at start time and exports BAO_API_ADDR and
# BAO_CLUSTER_ADDR, which is also why OpenBao's HCL is not asked to expand a shell variable: it does not,
# and an earlier version of this config carried a literal `https://${HOSTNAME}:8201` that was never
# substituted and never noticed.

storage "raft" {
  path    = "/var/lib/openbao"
  node_id = "openbao-1"

  # One node during alpha, so no peers and no retry_join. Above one node, add one block per OTHER node
  # and give each node a distinct node_id above:
  #
  #   retry_join { leader_api_addr = "https://<other-node-private-address>:8200" }
  #
  # D9 requires raising this to three before production approval. With one node there is no quorum, so
  # the daily Raft snapshot is the entire availability story rather than a background chore.
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"

  tls_cert_file      = "/etc/openbao/tls/server.crt"
  tls_key_file       = "/etc/openbao/tls/server.key"
  tls_client_ca_file = "/etc/openbao/tls/ca.crt"
}

# Audit, declared rather than enabled after unsealing. OpenBao 2.x removed API-based audit device
# management outright -- PUT /v1/sys/audit/file answers "cannot enable audit device via API; use
# declarative, config-based audit device management instead" -- so a runbook step that enables it during
# bootstrap could never have worked.
#
# Declaring it here is also strictly better than the step it replaces: the device exists from the first
# request, so the audit record covers initialization and unsealing rather than beginning after them.
# All three fields are required; the block label alone is not the path.
#
# /var/log/openbao is on the Droplet's own disk, not the Raft volume, because OpenBao refuses requests
# when every audit device fails to write -- an audit log growing into a full Raft volume would take the
# service down.
audit "file" {
  type = "file"
  path = "file/"
  options = {
    file_path = "/var/log/openbao/audit.log"
  }
}

# There is deliberately no `disable_mlock` here, and its absence is the single clearest gain of this
# appliance over the container it replaces.
#
# On the Debian nodes OpenBao ran as a non-root user inside a distroless image whose binary carried no
# cap_ipc_lock, so granting the capability to the container could not reach the process and the config
# had to set `disable_mlock = true`, with MemorySwapMax=0 standing in for the property mlock provides.
# Here the init script grants CAP_IPC_LOCK ambiently, so OpenBao locks its memory for real, and
# openbao-selfcheck asserts VmLck is non-zero rather than trusting that it did.
