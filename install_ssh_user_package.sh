#!/usr/bin/env bash

# should not run as root
[ "$EUID" -eq 0 ] && echo "This script should NOT be run using sudo" && exit 1

# the name of this script is ...
SCRIPT=$(basename "${0}")

# check parameters
if [ $# -ne 1 ] ; then
	cat <<-USAGE

	Usage: ${SCRIPT} package

	       package : path to user installation package (.tar.gz)
	                 required, no default

	USAGE
	exit 1
fi

# the expected package name is
PACKAGE_TAR_GZ="${1}"

# does the package exist?
if [ ! -f "${PACKAGE_TAR_GZ}" ] ; then
	echo "Error: ${PACKAGE_TAR_GZ} not found."
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
tar -x -z -f "${PACKAGE_TAR_GZ}" -C "${PACKAGE}"

# source the contents
CONTENTS="${PACKAGE}/.contents"
if [ -f "${CONTENTS}" ] ; then
	. "${CONTENTS}"
else
	echo "Error: ${CONTENTS} not found in package"
	exit 1
fi

# contents file is assumed to define
#	USER_PRIVATE		${SSH_USER}
#	USER_CERTIFICATE	${USER_PRIVATE}-cert.pub
#	USER_CONFIG			make_ssh_config_for_${SSH_USER}.sh
# no check for expected components - implied in install_component()

# the target directory is
SSH_DIR="${HOME}/.ssh"

# ensure the target directory exists
mkdir -p "${SSH_DIR}"

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

install_component "${PACKAGE}/${USER_PRIVATE}"     "${SSH_DIR}/${USER_PRIVATE}"     400
install_component "${PACKAGE}/${USER_CERTIFICATE}" "${SSH_DIR}/${USER_CERTIFICATE}" 600
install_component "${PACKAGE}/${USER_CONFIG}"      "${SSH_DIR}/${USER_CONFIG}"      700

echo "Done!"