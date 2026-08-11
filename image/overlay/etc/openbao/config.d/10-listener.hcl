# The API listener.
#
# **Structural**, and the most coupled fragment in the directory. `/etc/init.d/openbao` refuses to start
# unless all three files below are present and applies `root:openbao` and the right modes to them on every
# start; `/etc/init.d/openbao-volume` creates the directory with the ownership that lets a confined `bao`
# read it. Moving these paths means changing all three together.
#
# **They are on the attached volume, not the boot disk, since 2026-08-11.** That is what makes replacing a
# Droplet cheap: TLS reattaches with the volume, so nothing is copied back and the certificate -- which is
# about OpenBao's NAME rather than the node's address -- is still valid. The seal key deliberately did not
# move; it stays on the boot disk so that a snapshot of this volume is useless without it. See D23.
#
# `listener` is one of the stanzas that APPENDS across fragments rather than overriding. Adding a second
# one here gets you two listeners, not a replacement -- and a second on the same address fails to bind.
# To serve on different terms, replace this file rather than adding one beside it.
#
# **Replacing this file without a tls_cert_file turns ACME on rather than turning TLS off.** OpenBao
# 2.6.1 enables ACME by default when tls_cert_file is empty, pointed at Let's Encrypt production -- so a
# listener fragment that merely omits the certificate reaches out to a public CA, and its HTTP-01
# challenge takes a temporary bind on port 80. Measured: the server logs
# `listener-acme.maintenance: started background certificate maintenance` and reports `tls: "enabled"`
# with no certificate configured at all. That is a reasonable default for a node on the public internet
# and the wrong one for a node reached over a private address, which cannot complete the challenge and
# will keep trying. If you replace this fragment and mean to supply your own certificate, supply it; if
# you mean to use ACME, set tls_acme_domains and tls_acme_email deliberately. `openbao-selfcheck` reports
# which of the two is in effect.
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

  tls_cert_file      = "/var/lib/openbao/tls/server.crt"
  tls_key_file       = "/var/lib/openbao/tls/server.key"
  tls_client_ca_file = "/var/lib/openbao/tls/ca.crt"
}
