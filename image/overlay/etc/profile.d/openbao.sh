# shellcheck shell=sh
# Points the `bao` CLI at this node's own server, so an operator who logs in can use it.
#
# This exists because of what its absence made people do. The CLI verifies the server's certificate
# against a CA it has to be told about, and nothing on the image told it -- so the first command anybody
# ran on a node reported an x509 error naming an unknown authority, and the documented way out of that
# is `-tls-skip-verify`, which turns off certificate verification on the host holding every production
# credential. AGENTS.md says anything that makes an operator reach for that flag is a bug in this image.
# It was one, and this is the fix: not a warning against the flag but a reason not to need it.
#
# Read from the configuration rather than hard-coded, so it stays right for a node whose operator
# replaced 10-listener.hcl, moved the files, or uses ACME -- in which case the CA is a public one, the
# grep below finds nothing, and the CLI's own default trust store is correct with nothing set.
#
# Sourced by /etc/profile for every login shell, which is an interactive SSH session and the serial
# console. `ssh <node> <command>` runs a non-login shell and does NOT read this, so a one-off command
# over SSH still needs the variables passed; that is a property of sshd rather than something this file
# can fix, and PermitUserEnvironment is deliberately off.

# Only when there is a server to talk to. A node that has not been given TLS material yet has no
# listener running, and setting these would produce a connection error instead of the clearer message
# `openbao-selfcheck` gives.
if [ -x /usr/sbin/bao ] && [ -d /etc/openbao/config.d ]; then
	# The address the server ADVERTISES, not the loopback.
	#
	# The service exports BAO_API_ADDR=https://<private-address>:8200, which is what OpenBao tells its
	# clients to dial and therefore the address its certificate has to be valid for -- if it were not,
	# the Agent sidecars could not connect either. Using the same one from the CLI means the CLI
	# verifies exactly what every other client verifies, rather than a loopback name that a certificate
	# about this server's NAME has no reason to carry.
	_bao_address="$(cat /run/metadata/private-address 2>/dev/null || true)"
	[ -n "$_bao_address" ] || _bao_address=127.0.0.1
	[ -n "${BAO_ADDR:-}" ] || BAO_ADDR="https://${_bao_address}:8200"

	# The CA the listener is configured with, whatever path it is at.
	_bao_ca="$(grep -rhE '^[[:space:]]*tls_client_ca_file[[:space:]]*=' \
		/etc/openbao/config.d /run/openbao/config.d 2>/dev/null |
		sed -e 's/.*=[[:space:]]*//' -e 's/^"//' -e 's/".*$//' | head -1)"
	if [ -n "${BAO_CACERT:-}" ]; then
		:
	elif [ -n "$_bao_ca" ] && [ -r "$_bao_ca" ]; then
		BAO_CACERT="$_bao_ca"
	fi

	export BAO_ADDR
	[ -z "${BAO_CACERT:-}" ] || export BAO_CACERT
	unset _bao_address _bao_ca
fi
