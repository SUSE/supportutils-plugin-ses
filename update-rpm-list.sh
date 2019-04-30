#!/bin/bash
#
# Use this script to update the list of potentially installed
# RPMs to check.
#

SES_MEDIA_DIR=${1:-/srv/nfs/media/SUSE-Enterprise-Storage/}

[[ ! -d $SES_MEDIA_DIR ]] && echo "Directory doesn't exist: $SES_MEDIA_DIR" && exit 1

find $SES_MEDIA_DIR -name *.rpm | \
	sed 's/.*\///; s/-[0-9.~+A-Za-z_]\+-[0-9.]\+\.\(x86_64\|noarch\)\.rpm$//' | \
	grep -v '\.src\.rpm$' | \
	sort > ses-rpm-list
