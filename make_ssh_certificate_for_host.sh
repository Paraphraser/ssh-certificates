#!/usr/bin/env bash

# the name of this script is ...
SCRIPT=$(basename "${0}")

# check parameters
if [ $# -lt 2 ] ; then
	cat <<-USAGE

	Usage: ${SCRIPT} host domain {ipAddr {name ... } }

	         host : the name of the host
	       domain : your domain (eg your.home.arpa)
	       ipAddr : the IPv4 address of the host. Only needed to fetch the
	                host's public key if it is not already available (and
	                the host should be reachable at «ipAddr»); required if
	                if you want to pass one or more «name» fields
	         name : zero or more names (host name, domain name, mDNS name)
	                via which the host can be reached

	USAGE
	exit 1
fi

# only override with care - and be consistent
SSH_KEY_TYPE="${SSH_KEY_TYPE:-ed25519}"

# the arguments are (1+2 required, 3 is optional)
SSH_HOST="${1}"
SSH_DOMAIN="${2}"
SSH_IP_ADDR="${3}"

# directories
CA_DIR="${SSH_DOMAIN}/CA"
HOST_DIR="${SSH_DOMAIN}/hosts/${SSH_HOST}"

# try to load the certificate validity period from the cache
CERT_VALIDITY_CACHE=".validity"
CERT_VALIDITY="$(cat "${CA_DIR}/${CERT_VALIDITY_CACHE}" 2>/dev/null)"
CERT_VALIDITY="${CERT_VALIDITY:-"-1m:+730d"}"

# ensure directory exists for this host
mkdir -p "${HOST_DIR}"

# the paths to the files which are expected to exist at this point
USERCA_PUBLIC="user_${SSH_KEY_TYPE}_ca.pub"
HOSTCA_PRIVATE="host_${SSH_KEY_TYPE}_ca"
HOSTCA_PUBLIC="${HOSTCA_PRIVATE}.pub"

# check existence of expected files
for F in "${USERCA_PUBLIC}" "${HOSTCA_PRIVATE}" "${HOSTCA_PUBLIC}" ; do
	if [ ! -f "${CA_DIR}/${F}" ] ; then
		echo "Error: the following required file is missing:"
		echo "   ${CA_DIR}/${F}"
		exit 1
	fi
done

# files which may not exist at this point
HOST_PUBLIC="ssh_host_${SSH_KEY_TYPE}_key.pub"
GEN_CERTIFICATE="ssh_host_${SSH_KEY_TYPE}_key-cert.pub"
HOST_CERTIFICATE="ssh_host_${SSH_KEY_TYPE}_${SSH_DOMAIN}_key-cert.pub"
HOST_TRUSTED_KEYS="ssh_trusted_user_CA_public_keys"
HOST_PRINCIPALS="host_principals.csv"
HOST_GLUE="900_${SSH_DOMAIN}.conf"
HOST_ARCHIVE="${SSH_HOST}_etc-ssh.tar.gz"
KNOWN_HOSTS_RECORD="known_hosts_record"
HOST_KNOWN_HOSTS="ssh_known_hosts"
CONTENTS=".contents"

# was the IP address passed on the command line?
if [ -z "${SSH_IP_ADDR}" ] ; then

	# no! is the dig command available?
	if [ -n "$(which dig)" ] ; then
	
		# yes! let's see if we can discover the IP adress.
		SSH_IP_ADDR=$(dig +short ${SSH_HOST}.${SSH_DOMAIN} | head -1)

		# the most likely edge case is a blocked domain name returning
		# an IP address of 0.0.0.0 which, if used, would mean "self" so
		# sense that condition and clear it
		[ "${SSH_IP_ADDR}" = "0.0.0.0" ] && unset SSH_IP_ADDR

		# do we still have something that might be an IP address?
		[ -n "${SSH_IP_ADDR}" ] && \
		echo "Domain name ${SSH_HOST}.${SSH_DOMAIN} resolved to ${SSH_IP_ADDR}"

	else
	
		cat <<-NODIG
			Unable to query the DNS for the IP address of ${SSH_HOST}.${SSH_DOMAIN}
			Please re-run this command and pass the host's IP address as the third argument.
		NODIG

	fi

fi

# do we have an IP address?
if [ -n "${SSH_IP_ADDR}" ] ; then

	# yes! that means we can try to fetch the public key
	#
	#	For reasons that aren't at all clear, running:
	#
	#		ssh-keyscan -t ed25519 «ipAddr» 2>/dev/null
	#
	#	retrieves a file with this pattern:
	#
	#		«ipAddr» ssh-ed25519 «PUBLIC KEY DATA»
	#
	#	where the IP address at the start comes from the command line
	#	so if you use a hostname, domain name, or mDNS name on the
	#	command, that's what appears in the leading field.
	#
	#	However, if you COPIED /etc/ssh/ssh_host_ed25519_key.pub from
	#	the host using ssh, scp, or something else you'd get this:
	#
	#		ssh-ed25519 «PUBLIC KEY DATA» root@host
	#
	#	The "ssh-ed25519" and «PUBLIC KEY DATA» portions are the same.
	#
	#	The problem is that the "ssh-keygen -s" command hates having
	#	anything before the "ssh-ed25519" (but it doesn't care whether
	#	the "root@host" is present or absent).
	#
	#	The cut -d " " -f 2-3 command you see below deals with this
	#	problem but it sure seems like either a bug in ssh-keyscan or
	#	ssh-keygen (either the former is generating the wrong stuff
	#	or the latter hasn't been coded to accept what the former
	#	produces. I've filed a bug report about this, suggesting a
	#	command-line option for ssh-keyscan to omit the leading field.
	#
	#		https://bugzilla.mindrot.org/show_bug.cgi?id=3746

	echo -n "Trying to fetch ${SSH_KEY_TYPE} public key for ${SSH_HOST} from ${SSH_IP_ADDR} - "
	SSH_HOST_PUB_KEY="$(ssh-keyscan -4qt ${SSH_KEY_TYPE} "${SSH_IP_ADDR}" 2>/dev/null | cut -d " " -f 2-3)"

	# did the fetch succeed?
	if [ -n "${SSH_HOST_PUB_KEY}" ] ; then
		# yes! report and save
		echo "succeeded"
		echo "${SSH_HOST_PUB_KEY}" >"${HOST_DIR}/${HOST_PUBLIC}"
	else
		# no! report
		echo "failed - will use cached copy if available"
	fi

fi

# The host's public key is required for certificate creation. The ideal
# way to fetch it is via ssh-keyscan (as above). That depends on being
# able to reach the host so, in effect, passing the IP address of the
# host is mandatory on first run. On second-or-subsequent runs, it
# becomes optional but not passing the IP address means that the cached
# copy of the public key will be re-used for the updated certificate.
# In most cases, hosts do not change their public keys but it is still a
# possibility (eg rebuilding a host with the same name or explicitly
# instructing the host to regenerate its SSH key-pairs). If that happens
# the cached copy will be out-of-sync with the true public key and the
# certificate will be useless. The only solution is user-awareness of
# the need to either pass the IP address to cause a re-fetch or obtain
# a copy of the public key out-of-band.

# does the cached copy of the public key exist (-s is non-zero length)?
if [ ! -s "${HOST_DIR}/${HOST_PUBLIC}" ] ; then

	# no! did the user supply the IP address?
	if [ -n "${SSH_IP_ADDR}" ] ; then
	
		# yes! that means the fetch failed
		cat <<-MANUALKEY
			No public key available locally. You will need to obtain the following file from ${SSH_HOST}:
			   /etc/ssh/${HOST_PUBLIC}
			Copy that file to this host at the path:
			   ./${HOST_DIR}/${HOST_PUBLIC}
			Then, re-run this command.
		MANUALKEY

	else

		# no! that means ssh-keyscan could not be used
		cat <<-AUTOKEY
			No public key for ${SSH_HOST}. Please re-run this command
			and pass the host's IP address as the third argument.
		AUTOKEY

	fi

	exit 1

fi


# principals from command line take precedence
PRINCIPALS="${4}"
while [ $# -gt 4 ] ; do
	shift
	PRINCIPALS="${PRINCIPALS},${4}"
done

# alternatively, try to load from previous run
if [ -z "${PRINCIPALS}" -a -f "${HOST_DIR}/${HOST_PRINCIPALS}" ] ; then
	PRINCIPALS=$(cat "${HOST_DIR}/${HOST_PRINCIPALS}")
fi

# last option is to use a default (also catches empty cache)
if [ -z "${PRINCIPALS}" ] ; then
	# start with the host name
	PRINCIPALS="${SSH_HOST}"
	# then the fully-qualified domain name
	PRINCIPALS="${PRINCIPALS},${SSH_HOST}.${SSH_DOMAIN}"
	# then the multicast domain name
	PRINCIPALS="${PRINCIPALS},${SSH_HOST}.local"
	# add the IP address if it was provided
	[ -n "${SSH_IP_ADDR}" ] && PRINCIPALS="${PRINCIPALS},${SSH_IP_ADDR}"
fi

# cache the result for next time
echo "${PRINCIPALS}" > "${HOST_DIR}/${HOST_PRINCIPALS}"


# we have all we need to generate the certificate
ssh-keygen -q \
	-I "$SSH_HOST" \
	-s "${CA_DIR}/$HOSTCA_PRIVATE" \
	-h \
	-n "$PRINCIPALS" \
	-V "${CERT_VALIDITY}" \
	"${HOST_DIR}/${HOST_PUBLIC}"

# rename on success, moan otherwise
if [ -f "${HOST_DIR}/${GEN_CERTIFICATE}" ] ; then
	mv "${HOST_DIR}/${GEN_CERTIFICATE}" "${HOST_DIR}/${HOST_CERTIFICATE}"
else
	echo "Error: Certificate for ${SSH_HOST} could not be generated"
	exit 1
fi

# construct a directory to hold the package
PACKAGE=$(mktemp -d "/tmp/${SCRIPT}.XXXXX")

# copy files into place
cp  "${CA_DIR}/${USERCA_PUBLIC}" \
	"${HOST_DIR}/${HOST_CERTIFICATE}" \
	"${PACKAGE}/."

# construct the known-hosts record
# @cert-authority «principals» «options» «keytype» «base64-encoded-key»
cat <<-HOSTS >"${PACKAGE}/${KNOWN_HOSTS_RECORD}"
@cert-authority *.${SSH_DOMAIN},*.local $(cat ${CA_DIR}/${HOSTCA_PUBLIC})
HOSTS

# construct glue records
cat <<-GLUE >"${PACKAGE}/${HOST_GLUE}"
# Darwin sudo launchctl kickstart -k system/com.openssh.sshd
# Linux  sudo systemctl restart ssh
HostCertificate /etc/ssh/${HOST_CERTIFICATE}
TrustedUserCAKeys /etc/ssh/${HOST_TRUSTED_KEYS}
GLUE

# add key facts about the package contents
cat <<-FACTS >"${PACKAGE}/${CONTENTS}"
HOST_PUBLIC="${HOST_PUBLIC}"
HOST_CERTIFICATE="${HOST_CERTIFICATE}"
HOST_GLUE="${HOST_GLUE}"
HOST_KNOWN_HOSTS="${HOST_KNOWN_HOSTS}"
HOST_TRUSTED_KEYS="${HOST_TRUSTED_KEYS}"
KNOWN_HOSTS_RECORD="${KNOWN_HOSTS_RECORD}"
USERCA_PUBLIC="${USERCA_PUBLIC}"
FACTS

# archive the package
tar -czf "${HOST_DIR}/${HOST_ARCHIVE}" --no-xattrs -C "${PACKAGE}" .

# clean up
rm -rf "${PACKAGE}"

# debugging
if [ -n "${SSH_DEBUG}" ] ; then

	echo "Host-CA fingerprint:"
	ssh-keygen -l -f "${CA_DIR}/${HOSTCA_PRIVATE}" | sed -e "s/^/  /"
	echo "Host ${SSH_HOST} fingerprint:"
	ssh-keygen -l -f "${HOST_DIR}/${HOST_PUBLIC}" | sed -e "s/^/  /"
	echo "Host certificate for ${SSH_HOST}:"
	ssh-keygen -L -f "${HOST_DIR}/${HOST_CERTIFICATE}" | sed -e "s/^/  /"

else

	echo "Host certificate fingerprint:"
	ssh-keygen -l -f "${HOST_DIR}/${HOST_CERTIFICATE}" | sed -e "s/^/  /"

fi
