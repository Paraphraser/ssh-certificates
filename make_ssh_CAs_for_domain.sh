#!/usr/bin/env bash

# the name of the script is
SCRIPT=$(basename "${0}")

# one argument required
if [ $# -lt 1 -o $# -gt 3 ] ; then
	cat <<-USAGE

	Usage: ${SCRIPT} domain { days }

	          domain : your domain (eg your.home.arpa)
	            days : certificate validity period. Defaults to 730 days.
	                   Use 0 (zero) for certificates that never expire.

	USAGE
	exit 1
fi

# only override with care - and be consistent
SSH_KEY_TYPE="${SSH_KEY_TYPE:-ed25519}"

# the arguments are
SSH_DOMAIN="${1}"
SSH_CERT_DAYS="${2:-730}"

# try to ensure days is numeric (will be zero for most non-numerics but
# there are pathological cases which will still fail like ".")
SSH_CERT_DAYS=$((SSH_CERT_DAYS*1))

# anything less than one day becomes always
if [ ${SSH_CERT_DAYS} -lt 1 ] ; then
	CERT_VALIDITY="-1m:forever"
else
	CERT_VALIDITY="-1m:+${SSH_CERT_DAYS}d"
fi

# all generation occurs in a domain directory
GIT_IGNORE="${SSH_DOMAIN}/.gitignore"
CA_DIR="${SSH_DOMAIN}/CA"
HOSTS_DIR="${SSH_DOMAIN}/hosts"
USERS_DIR="${SSH_DOMAIN}/users"

# ensure those directories exist
mkdir -p "${CA_DIR}" "${HOSTS_DIR}" "${USERS_DIR}"

# it's a good idea to exclude that by default (but don't overwrite
# because the user may comment-out the wildcard)
[ -f "${GIT_IGNORE}" ] || echo "*" >"${GIT_IGNORE}"

# this script generates (*_ca = private key, *_ca.pub = public key)
HOST_CA="host_${SSH_KEY_TYPE}_ca"
USER_CA="user_${SSH_KEY_TYPE}_ca"
CERT_VALIDITY_CACHE=".validity"

# cache validity
echo "${CERT_VALIDITY}" >"${CA_DIR}/${CERT_VALIDITY_CACHE}"

# generate the host certificate authority (public/private key-pair)
if [ ! -f "${CA_DIR}/${HOST_CA}" ] ; then
	ssh-keygen -q \
		-t "${SSH_KEY_TYPE}" \
		-P "" \
		-f "${CA_DIR}/${HOST_CA}" \
		-C "host-CA generated $(date +'%d-%m-%Y')"
fi

# generate the user certificate authority (public/private key-pair)
if [ ! -f "${CA_DIR}/${USER_CA}" ] ; then
	ssh-keygen -q \
		-t "${SSH_KEY_TYPE}" \
		-P "" \
		-f "${CA_DIR}/${USER_CA}" \
		-C "user-CA generated $(date +'%d-%m-%Y')"
fi

# ensure correct permissions on private keys (unconditional)
chmod 600 "${CA_DIR}/${HOST_CA}" "${CA_DIR}/${USER_CA}"

echo "CA fingerprints:"
ssh-keygen -l -f "${CA_DIR}/${HOST_CA}.pub" | sed -e "s/^/  /"
ssh-keygen -l -f "${CA_DIR}/${USER_CA}.pub" | sed -e "s/^/  /"

echo -e "Certificates will have the validity period:\n  $CERT_VALIDITY"

