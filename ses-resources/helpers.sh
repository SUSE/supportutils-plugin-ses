#!/bin/bash

# Source this to import helper functions
# for the SUSE Enterprise Storage supportutils plugin

print_error() {
    echo "ERROR: $*"
}

# Helper function liberated from Matt Barringer's supportutils-plugin-susecloud
validate_rpm_if_installed() {
    local thisrpm="$1"
    echo "#==[ Validating RPM ]=================================#"
    if rpm -q "$thisrpm" >/dev/null 2>&1; then
        echo "# rpm -V $thisrpm"

        if rpm -V "$thisrpm"; then
            echo "Status: Passed"
        else
            echo "Status: WARNING"
        fi
    else
        echo "package $thisrpm is not installed"
        echo "Status: Skipped"
    fi
    echo
}
