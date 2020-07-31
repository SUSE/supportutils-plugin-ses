#!/bin/bash

# Source this to import helper functions
# for the SUSE Enterprise Storage supportutils plugin

#############################################################

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

#############################################################
# Collect advanced/admin debug information about a Ceph daemon, and log it into the appropriate
# directory. This information should then be the same for all backends
collect_info_from_daemon() {
    local daemon="$1" # e.g., "mon.b", "osd.5", "mds.b"
    local container_shell="$2" # e.g., "cephadm enter --name mon.b --" or "kubectl -n rook-ceph exec <pod> -- env -i"

    local logdir="$DAEMONLOG"/"$daemon"
    mkdir "$logdir"
    plugin_message "  collecting information about daemon $daemon > $logdir"

    local ceph_daemon_cmd="$container_shell $CEPH daemon $daemon"

    if [[ "$daemon" =~ ^(mon|mgr|mds|osd) ]] ; then
        plugin_command "$ceph_daemon_cmd config show" > "$logdir"/ceph-daemon-config 2>&1
        plugin_command "$ceph_daemon_cmd perf dump" > "$logdir"/ceph-daemon-perf 2>&1
    fi

    case $daemon in
    mds.*)
        plugin_command "$ceph_daemon_cmd dump_historic_ops" > "$logdir"/ceph-daemon-historic_ops 2>&1
        plugin_command "$ceph_daemon_cmd status" > "$logdir"/ceph-daemon-status 2>&1
        plugin_command "$ceph_daemon_cmd get subtrees" > "$logdir"/ceph-daemon-subtrees 2>&1
        ;;
    mgr.*)
        plugin_command "$ceph_daemon_cmd status" > "$logdir"/ceph-daemon-status 2>&1
        ;;
    mon.*)
        plugin_command "$ceph_daemon_cmd dump_historic_ops" > "$logdir"/ceph-daemon-historic_ops 2>&1
        ;;
    osd.*)
        plugin_command "$ceph_daemon_cmd dump_historic_ops" > "$logdir"/ceph-daemon-historic_ops 2>&1
        plugin_command "$ceph_daemon_cmd dump_ops_in_flight" > "$logdir"/ceph-daemon-ops_in_flight 2>&1
        plugin_command "$ceph_daemon_cmd status" > "$logdir"/ceph-daemon-status 2>&1
        plugin_command "$ceph_daemon_cmd dump_watchers" > "$logdir"/ceph-daemon-watchers 2>&1
        ;;
    nfs.*)
        plugin_command "$container_shell cat /etc/ganesha/ganesha.conf" > "$logdir"/ganesha-config 2>&1
        # UserId and userid are both valid: use --ignore-case
        local nfs_user nfs_pool nfs_ns
        nfs_user="$(_get_value_from_nfs_config "$logdir"/ganesha-config userid)"
        nfs_pool="$(_get_value_from_nfs_config "$logdir"/ganesha-config pool)"
        nfs_ns="$(_get_value_from_nfs_config "$logdir"/ganesha-config namespace)"
        local rados_cmd="$container_shell rados --id=$nfs_user --pool=$nfs_pool --namespace=$nfs_ns"
        plugin_command "$rados_cmd ls" >> "$logdir"/ganesha-config 2>&1
        for o in $($rados_cmd ls 2>/dev/null) ; do
            [[ "$o" =~ ^(conf-|export-) ]] || continue
            plugin_command "$rados_cmd get $o -" 2>&1 |
                sed "s/\(secret_access_key = \"\).*\(\"\)/\1$CENSORED\"/g" >> "$logdir"/ganesha-config
        done
        ;;
    iscsi.*)
        # NOTE: Rook does not support iSCSI yet
        plugin_command "$container_shell gwcli export" 2>&1 |
            sed "s/\(password\": \"\).*\"/\1$CENSORED\"/g" >> "$logdir"/gwcli-export
        ;;
    prometheus.*)
        # TODO: support Rook w/ Prometheus
        # cephadm configures the prometheus container to store
        # metrics in /prometheus, not /var/lib/prometheus/metrics
        plugin_command "$container_shell du -s /prometheus" > "$logdir"/prometheus-du
        plugin_command "$container_shell du -hs /prometheus" >> "$logdir"/prometheus-du
        ;;
    esac
}

# search a file containing NFS-Ganesha configs for a particular config key, and get the value of it.
_get_value_from_nfs_config() {
    local config_file="$1"
    local config_setting="$2"
    # NFS config lines can be in a few forms.
    # Known forms: [   key = value;], [   key = "value";], [   key = 'value';]
    # some configs can be in different cases (e.g., UserId and userid are the same): use --ignore-case
    local config_line
    config_line="$(grep --ignore-case --max-count=1 "$config_setting =" "$config_file")"
    local val="${config_line#* = }" # get value portion by cutting everything up to and including ' = '
    val="${val%;}" # strip the ';' off the end
    # the below won't handle cases where a legitimate string might end or begin with unmatched
    # quotes, but that case seems rare in this context
    val="${val%[\'\"]}" # strip any single- or double-quotes off the end
    val="${val#[\'\"]}" # strip any single- or double-quotes off the beginning
    echo "$val"
}

#############################################################
