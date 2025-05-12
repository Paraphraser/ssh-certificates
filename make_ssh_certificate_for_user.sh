#!/usr/bin/env bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# check parameters
if [ $# -lt 2 ] ; then
	cat <<-USAGE

	Usage: ${SCRIPT} sshUser domain {account ...}

	       sshUser : the name associated with keys for this user
	        domain : your domain (eg your.home.arpa)
	       account : zero or more account names. Optional. If omitted on
	                 first run, defaults to using sshUser as an account
	                 name. Thereafter, account names are retrieved from
	                 sshUser's user_principals.csv until overridden by
	                 passing at least one account name.

	USAGE
	exit 1
fi

# only override with care - and be consistent
SSH_KEY_TYPE="${SSH_KEY_TYPE:-ed25519}"

# the arguments are
SSH_USER="${1}"
SSH_DOMAIN="${2}"

# directories
CA_DIR="${SSH_DOMAIN}/CA"
CERT_VALIDITY_CACHE="${CA_DIR}/.validity"
USER_DIR="${SSH_DOMAIN}/users/${SSH_USER}"

# try to load the certificate validity period from the cache
CERT_VALIDITY="$(cat "${CERT_VALIDITY_CACHE}" 2>/dev/null)"
CERT_VALIDITY="${CERT_VALIDITY:-"-1m:+730d"}"

# ensure directory exists for this user
mkdir -p "${USER_DIR}"

# the user CA private key is expected to exist at this point
USERCA_PRIVATE="user_${SSH_KEY_TYPE}_ca"
HOSTCA_PUBLIC="host_${SSH_KEY_TYPE}_ca.pub"

# check existence of expected files
for F in "${USERCA_PRIVATE}" "${HOSTCA_PUBLIC}" ; do
	if [ ! -f "${CA_DIR}/${F}" ] ; then
		echo "Error: the following required file is missing:"
		echo "   ${CA_DIR}/${F}"
		exit 1
	fi
done

# files which may not exist at this point
USER_PRIVATE="${SSH_USER}"
USER_PUBLIC="${USER_PRIVATE}.pub"
USER_CERTIFICATE="${USER_PRIVATE}-cert.pub"
USER_PRINCIPALS="user_principals.csv"
USER_CONFIG="make_ssh_config_for_${SSH_USER}.sh"
USER_ARCHIVE="${SSH_USER}_dot-ssh.tar.gz"
CONTENTS=".contents"

# generate user key-pair if it neither component exists
if ! [ -f "${USER_DIR}/${USER_PRIVATE}" -o -f "${USER_DIR}/${USER_PUBLIC}" ] ; then
	ssh-keygen -q \
		-t "${SSH_KEY_TYPE}" \
		-P "" \
		-f "${USER_DIR}/${USER_PRIVATE}" \
		-C "key-pair for ${SSH_USER} in ${SSH_DOMAIN} generated $(date +'%d-%m-%Y')"
fi

# at this point, EITHER both the user private and public key exist
# (either because they already existed when the script started, or
# because they have just been generated), OR we only have one of
# the pair, which leaves us in an inconsistent state.
for F in "${USER_PRIVATE}" "${USER_PUBLIC}" ; do
	if [ ! -f "${USER_DIR}/${F}" ] ; then
		echo "Error: the following required file is missing:"
		echo "   ${USER_DIR}/${F}"
		exit 1
	fi
done


# see if there are any principals on the command line
PRINCIPALS="${3}"
while [ $# -gt 3 ] ; do
	shift
	PRINCIPALS="${PRINCIPALS},${3}"
done

# no principals on command line - try to load from cache
if [ -z "${PRINCIPALS}" -a -f "${USER_DIR}/${USER_PRINCIPALS}" ] ; then
	PRINCIPALS=$(cat "${USER_DIR}/${USER_PRINCIPALS}")
fi

# last option is to use the SSH user name
PRINCIPALS=${PRINCIPALS:-"${SSH_USER}"}

# save whatever principals emerged
echo "${PRINCIPALS}" > "${USER_DIR}/${USER_PRINCIPALS}"

# the inputs to the certificate-generation process are
# 1. the private key for the user CA
# 2. the name of the user the certificate is being generated for
# 3. the public key of the the user the certificate is being generated for
# 4. whatever "user principals" emerged above
# We have all four. Go for it
ssh-keygen -q \
	-I "${USER_DIR}/${SSH_USER}" \
	-s "${CA_DIR}/${USERCA_PRIVATE}" \
	-n "${PRINCIPALS}" \
	-V "${CERT_VALIDITY}" \
	"${USER_DIR}/${USER_PUBLIC}"

# moan on failure
if [ ! -f "${USER_DIR}/${USER_CERTIFICATE}" ] ; then
	echo "Error: Certificate for ${SSH_USER} could not be generated"
	exit 1
fi

# construct a directory to hold the package
PACKAGE=$(mktemp -d "/tmp/${SCRIPT}.XXXXX")

# copy files into place
cp  "${USER_DIR}/${USER_PRIVATE}" \
	"${USER_DIR}/${USER_CERTIFICATE}" \
	"${PACKAGE}/."

# construct a template for ~/.ssh/config
cat <<-CONFIG_SCRIPT >"${PACKAGE}/${USER_CONFIG}"
#!/usr/bin/env bash

SCRIPT=\$(basename "\${0}")

if [ \$# -ne 2 ] ; then
	cat <<-USAGE

	Usage: \${SCRIPT} account target { >>~/.ssh/config }

	       account : the account name you use to login on the target host
	        target : the host name (NOT domain name) you want to connect to

	USAGE
	exit 1
fi

ACCOUNT=\$(echo "\$1" | tr -dc '[:alnum:]-')
TARGET=\$(echo "\$2" | tr -dc '[:alnum:]-' | tr '[:upper:]' '[:lower:]')

cat <<-TEMPLATE

host \$TARGET
  hostname %h.${SSH_DOMAIN}
  user \$ACCOUNT
  IdentitiesOnly yes
  IdentityFile ~/.ssh/$SSH_USER

host \$TARGET.*
  hostname %h
  user \$ACCOUNT
  IdentitiesOnly yes
  IdentityFile ~/.ssh/$SSH_USER

TEMPLATE
CONFIG_SCRIPT

# the script needs to be executable
chmod +x "${PACKAGE}/${USER_CONFIG}"

# add key facts about the package contents
cat <<-FACTS >"${PACKAGE}/${CONTENTS}"
USER_PRIVATE="${USER_PRIVATE}"
USER_CERTIFICATE="${USER_CERTIFICATE}"
USER_CONFIG="${USER_CONFIG}"
FACTS

# archive the package file
tar -czf "${USER_DIR}/${USER_ARCHIVE}" --no-xattrs -C "${PACKAGE}" .

# clean up
rm -rf "${PACKAGE}"

# debugging
if [ -n "${SSH_DEBUG}" ] ; then

	echo "User-CA fingerprint:"
	ssh-keygen -l -f "${CA_DIR}/${USERCA_PRIVATE}" | sed -e "s/^/  /"
	echo "User ${SSH_USER} fingerprint:"
	ssh-keygen -l -f "${USER_DIR}/${USER_PUBLIC}" | sed -e "s/^/  /"
	echo "User certificate for ${SSH_USER}:"
	ssh-keygen -L -f "${USER_DIR}/${USER_CERTIFICATE}" | sed -e "s/^/  /"

else

	echo "User certificate fingerprint:"
	ssh-keygen -l -f "${USER_DIR}/${USER_CERTIFICATE}" | sed -e "s/^/  /"

fi
