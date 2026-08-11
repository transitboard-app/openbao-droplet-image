# The API listener.
#
# **Structural**, and the most coupled fragment in the directory. `/etc/init.d/openbao` refuses to start
# unless all three files below are present, applies `root:openbao` and the right modes to them on every
# start, and the AppArmor profile grants reads on that directory and nowhere else. Moving the TLS paths
# means changing all three together.
#
# `listener` is one of the stanzas that APPENDS across fragments rather than overriding. Adding a second
# one here gets you two listeners, not a replacement -- and a second on the same address fails to bind.
# To serve on different terms, replace this file rather than adding one beside it.
#
# api_addr and cluster_addr are deliberately absent. Each has to be this node's own private address,
# which is not known when this image is built -- an image predates every Droplet that will boot it. The
# init script reads the address from the metadata service at start time and exports BAO_API_ADDR and
# BAO_CLUSTER_ADDR, which is also why OpenBao's HCL is not asked to expand a shell variable: it does not,
# and an earlier version of this config carried a literal `https://${HOSTNAME}:8201` that was never
# substituted and never noticed.

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"

  tls_cert_file      = "/etc/openbao/tls/server.crt"
  tls_key_file       = "/etc/openbao/tls/server.key"
  tls_client_ca_file = "/etc/openbao/tls/ca.crt"
}
