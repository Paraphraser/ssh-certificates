#!/usr/bin/env bash

# must be run as root
[ "$EUID" -ne 0 ] && echo "This script MUST be run using sudo" && exit 1

# the name of this script is ...
SCRIPT=$(basename "${0}")

# the default hoatname is (using "tr" rather than bash ",," because that
# doesn't work with the obsolete version of bash which ships with macOS)
DEFAULT_TAR_GZ="$(hostname -s | tr '[:upper:]' '[:lower:]')_etc-ssh.tar.gz"
PACKAGE_TAR_GZ="${1:-"${DEFAULT_TAR_GZ}"}"

# can we find the package?
if [ ! -f "${PACKAGE_TAR_GZ}" ] ; then

	# no! treat this as a usage problem
	cat <<-USAGE

	Usage: ${SCRIPT} { package }

	       package : path to host installation package (.tar.gz)
	                 optional, defaults to "${PACKAGE_TAR_GZ}"

	USAGE

	exit 1

fi

# make a temporary directory to unpack into
PACKAGE=$(mktemp -d "/tmp/${SCRIPT}.XXXXX")

# ensure temporary directory cleaned-up
termination_handler() {
	rm -rf "${PACKAGE}"
}
trap termination_handler EXIT

# unpack
echo "Found ${PACKAGE_TAR_GZ} - unpacking"
tar -x --same-owner -z -f "${PACKAGE_TAR_GZ}" -C "${PACKAGE}"

# source the contents
CONTENTS="${PACKAGE}/.contents"
if [ -f "${CONTENTS}" ] ; then
	. "${CONTENTS}"
else
	echo "Error: ${CONTENTS} not found in package"
	exit 1
fi

# contents file is assumed to define
#	KNOWN_HOSTS_RECORD	known_hosts_record
#	USERCA_PUBLIC		user_${SSH_KEY_TYPE}_ca.pub
#	HOST_CERTIFICATE	ssh_host_${SSH_KEY_TYPE}_${SSH_DOMAIN}_key-cert.pub
#	HOST_GLUE			900-${SSH_DOMAIN}.conf

# check for expected components
for F in "${KNOWN_HOSTS_RECORD}" "${USERCA_PUBLIC}" "${HOST_CERTIFICATE}" "${HOST_GLUE}" ; do
	if [ ! -f "${PACKAGE}/${F}" ] ; then
		echo "Error: ${F} not found in package"
		exit 1
	fi
done

# contents also defines
#	HOST_TRUSTED_KEYS	ssh_trusted_user_CA_public_keys
#	HOST_KNOWN_HOSTS	ssh_known_hosts
#	HOST_PUBLIC			ssh_host_${SSH_KEY_TYPE}_key.pub

# useful function to extract the so-called-"bubble-babble" signature
# of a key or certificate.
#
# $1 = key or certificate file
#
# if $1 exists, extracts and returns bubble-babble + return code 0
# otherwise returns the filename + return code 1
signature_of() {
	# does the source file exist?
	if [ -f "${1}" ] ; then
		echo $(ssh-keygen -B -f "${1}" | awk '{print $2}')
		return 0
	fi
	echo "${1}"
	return 1
}

# useful function which iterates a source file line by line and appends
# the line to the target if and only if (a) the line is non-null and the
# line is not already present in the target. In the "while" statement:
#    IFS= prevents trimming of surrounding whitespace,
#    -r   backslash chars are considered to be part of the line
#    the || clause includes the final line if it isn't LF terminated
# In the "grep" command:
#    -q   silences output
#    -x   only whole lines match
#    -F   pattern to -e is a fixed string
# Mode 644 enforced for all destination files
#
# $1 = source file
# $2 = target file
#
append_unique_content() {
	chmod 644 "${1}"
	while IFS= read -r LINE || [ -n "$LINE" ] ; do
		if [ -n "$LINE" ] ; then
			if [ ! -f "${2}" ] || ! grep -qxF -e "${LINE}" "${2}" ; then
				echo "${LINE}" >>"${2}"
			fi
		fi
	done < "${1}"
}

# useful function replaces a file if it has changed (options on cp which
# can accomplish some/all of this are not consistent across Linux/macOS)
#
# $1 = source file
# $2 = target file
# $3 = mode
install_component ()
{
	if [ -e "${1}" ] ; then
		if [ -e "${2}" ] ; then
			cmp -s "${1}" "${2}"
			if [ $? -eq 0 ] ; then
				echo "${2} did not change"
			else
				rm -f "${2}"
				cp -v "${1}" "${2}"
			fi
		else
			cp -v "${1}" "${2}"
		fi
		chmod "${3}" "${2}"
	else
		echo "Error: $1 missing from $PACKAGE_TAR_GZ"
		exit 1
	fi
}

# verify that the incoming certificate matches the host's public key
HOST_BB=$(signature_of "/etc/ssh/${HOST_PUBLIC}")
CERT_BB=$(signature_of "${PACKAGE}/${HOST_CERTIFICATE}")
if [ "${HOST_BB}" != "${CERT_BB}" ] ; then
	cat <<-MISMATCH

		Error: Host certificate
		         ${HOST_CERTIFICATE}
		       in package
		         $PACKAGE_TAR_GZ
		       does not match this host's public key in
		         /etc/ssh/${HOST_PUBLIC}

		Installation can't proceed until this problem is resolved.

		1. Make sure you are using the correct package for this host.

		2. Make sure ${HOST_PUBLIC} in the folder structure where you
		   generated this host's certificate is the same as
		     /etc/ssh/${HOST_PUBLIC}
		   on this host.

		   Hint: you can remove ${HOST_PUBLIC} from the folder structure
		         where you generated this host's certificate and then re-run:

		           make_ssh_certificate_for_host «host» «domain» «ipAddr»

		         That will re-fetch ${HOST_PUBLIC}, regenerated the certificate
		         and construct a new package.

	MISMATCH
	exit 1
fi

# let's start with the glue. Does the destination directory exist?
echo "Installing configuration glue records"
if [ -d "/etc/ssh/sshd_config.d" ] ; then

	# yes! modern style - replace sshd_config.d/900-${SSH_DOMAIN}.conf
	install_component "${PACKAGE}/${HOST_GLUE}" "/etc/ssh/sshd_config.d/${HOST_GLUE}" 644

else

	# no! old-style - append to sshd_config.
	append_unique_content "${PACKAGE}/${HOST_GLUE}" "/etc/ssh/sshd_config"

fi

# the known hosts list (644 recommended in man sshd)
echo "Installing known hosts record"
append_unique_content "${PACKAGE}/${KNOWN_HOSTS_RECORD}" "/etc/ssh/${HOST_KNOWN_HOSTS}"

# the user CA public key
echo "Installing user CA public key"
append_unique_content "${PACKAGE}/${USERCA_PUBLIC}" "/etc/ssh/${HOST_TRUSTED_KEYS}"

# the certificate is always a direct copy
echo "Installing host certificate"
install_component "${PACKAGE}/${HOST_CERTIFICATE}" "/etc/ssh/${HOST_CERTIFICATE}" 644


# restart ssh daemon as per OS conventions
case "$(uname -s)" in

	"Darwin" )
		echo "Asking launchctl to kickstart sshd"
		launchctl kickstart -k system/com.openssh.sshd
	;;

	"Linux" )
		echo "Asking systemctl to restart ssh service"
		# and, yes, ssh (not sshd) is correct
		systemctl restart ssh
	;;

	*)
		echo "Unable to identify operating system to determine how to restart sshd."
		echo "You will need to figure this out for yourself."
	;;

esac

echo "Done!"