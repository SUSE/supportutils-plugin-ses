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
# Collect information from the Ceph CLI
collect_info_from_ceph_cli() {
    local ceph_shell="$1"

    # A command we are trying to call could hang or fail for myriad reasons, so add a timeout to all
    # calls. Use a multiplier of Ceph's connect timeout so that Ceph's timeout, if it occurs, is
    # sure to happen before the timeout command times out; this will give better error info.
    ceph_shell="$ceph_shell timeout $((CT * 2))"

    if ! plugin_command "$ceph_shell $CEPH --status" > "$CEPHLOG"/ceph-status 2>&1; then
        print_error "ceph --status failed (missing ceph.conf or admin keyring on host?)"
        return 1
    fi
    # For cephadm, none of the following will actually work without ceph.conf present on the host
    # and a valid keyring. Calling the above as a test gives us actual ceph status if everything is
    # working, or a helpful error message if not.

    plugin_message "Collecting basic Ceph cluster info > $CEPHLOG/..."

    plugin_command "$ceph_shell $CEPH versions" > "$CEPHLOG"/ceph-versions 2>&1
    plugin_command "$ceph_shell $CEPH health detail" > "$CEPHLOG"/ceph-health-detail 2>&1
    plugin_command "$ceph_shell $CEPH config dump" > "$CEPHLOG"/ceph-config-dump 2>&1
    plugin_command "$ceph_shell $CEPH mon dump" > "$CEPHLOG"/ceph-mon-dump 2>&1
    plugin_command "$ceph_shell $CEPH mgr dump" > "$CEPHLOG"/ceph-mgr-dump 2>&1
    plugin_command "$ceph_shell $CEPH osd tree" > "$CEPHLOG"/ceph-osd-tree 2>&1
    plugin_command "$ceph_shell $CEPH osd df tree" > "$CEPHLOG"/ceph-osd-df-tree 2>&1
    plugin_command "$ceph_shell $CEPH osd dump" > "$CEPHLOG"/ceph-osd-dump 2>&1
    plugin_command "$ceph_shell $CEPH osd pool autoscale-status" > "$CEPHLOG"/ceph-osd-pool-autoscale-status 2>&1
    plugin_command "$ceph_shell $CEPH osd pool ls detail" > "$CEPHLOG"/ceph-osd-pool-ls-detail 2>&1
    plugin_command "$ceph_shell $CEPH df detail" > "$CEPHLOG"/ceph-df-detail 2>&1
    plugin_command "$ceph_shell $CEPH fs dump -f json-pretty" > "$CEPHLOG"/ceph-fs-dump.json 2>&1
    plugin_command "$ceph_shell $CEPH fs dump" > "$CEPHLOG"/ceph-fs-dump 2>&1
    plugin_command "$ceph_shell $CEPH pg dump -f json-pretty" > "$CEPHLOG"/ceph-pg-dump.json 2>&1
    plugin_command "$ceph_shell $CEPH pg dump" > "$CEPHLOG"/ceph-pg-dump 2>&1
    plugin_command "$ceph_shell $CEPH auth list" 2>&1 |
        grep --invert-match 'installed auth entries' |
        sed "s/\(key:\) .*/\1 $CENSORED/g" > "$CEPHLOG"/ceph-auth-list
    # 'ceph report' does actually include the above information, but
    # in JSON format.  Since adding `ceph report`, the above commands
    # remain, because their output is easier to read in a hurry ;)
    plugin_command "$ceph_shell $CEPH report" > "$CEPHLOG"/ceph-report 2>&1
    plugin_command "$ceph_shell rados df" > "$CEPHLOG"/rados-df 2>&1
    plugin_command "$ceph_shell $CEPH telemetry status" > "$CEPHLOG"/ceph-telemetry-status 2>&1
    plugin_command "$ceph_shell $CEPH balancer status" > "$CEPHLOG"/ceph-balancer-status 2>&1

    # Orchestrator module
    plugin_message "Collecting Ceph orchestrator module info > $CEPHLOG/ceph-orch-status"
    {
        plugin_command "$ceph_shell $CEPH orch status" 2>&1
        plugin_command "$ceph_shell $CEPH cephadm get-ssh-config" 2>&1
        plugin_command "$ceph_shell $CEPH orch ls --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch host ls --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch ps --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch device ls --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch upgrade status" 2>&1
    } > "$CEPHLOG"/ceph-orch-status

    # RBD pool images
    plugin_message "Collecting information about RBD pool images > $CEPHLOG/rbd-images/..."
    $ceph_shell ceph osd pool ls detail -f json-pretty 2>/dev/null |
        jq -r '.[] | select(.application_metadata.rbd != null) | .pool_name' |
        while read pool; do
            mkdir --parents "$CEPHLOG"/rbd-images
            plugin_command "$ceph_shell rbd ls $pool" > "$CEPHLOG/rbd-images/rbd-ls-$pool" 2>&1
            $ceph_shell rbd ls $pool 2>/dev/null |
                head -n $RBD_INFO_MAX |
                while read image; do
                    mkdir --parents "$CEPHLOG/rbd-images/pool-$pool" # only create this dir if the pool has images
                    plugin_command "$ceph_shell rbd -p $pool info $image" > "$CEPHLOG/rbd-images/pool-$pool/rbd-info-$image" 2>&1
                done
        done

    # RGW information if RGW running
    if $ceph_shell ceph osd pool ls detail 2>/dev/null | grep -q "application rgw"; then
        plugin_message "Collecting info about RADOS gateways (RGWs) > $CEPHLOG/radosgw-..."
        plugin_command "$ceph_shell radosgw-admin period get" > "$CEPHLOG"/radosgw-admin-period-get 2>&1
        plugin_command "$ceph_shell radosgw-admin bucket stats" > "$CEPHLOG"/radosgw-admin-bucket-stats 2>&1
        plugin_command "$ceph_shell radosgw-admin bucket limit check" >> "$CEPHLOG"/radosgw-admin-bucket-stats 2>&1
        plugin_command "$ceph_shell radosgw-admin metadata list bucket.instance" >> "$CEPHLOG"/radosgw-admin-bucket-stats 2>&1
    else
        plugin_message "No RADOS gateways (RGWs) to collect info from"
    fi

    # Inactive PGs
    IPGLOG="$CEPHLOG"/inactive-pgs
    plugin_message "Collecting info about inactive PGs > $IPGLOG/..."
    plugin_command "$ceph_shell $CEPH pg dump_stuck inactive" > "$CEPHLOG"/ceph-pg-dump_stuck-inactive 2>&1
    $ceph_shell $CEPH pg dump_stuck inactive -f json-pretty 2>/dev/null |
        jq -r '.stuck_pg_stats[].pgid' |
        head -n $INACTIVE_PG_QUERY_MAX |
        while read pg; do
            mkdir --parents "$IPGLOG" # only create this dir if there are inactive PGs to log
            plugin_command "$ceph_shell $CEPH pg $pg query" > "$IPGLOG/ceph-pg-$pg-query" 2>&1
        done

    # Crash collector
    plugin_message "Collecting crash dump info > $CEPHLOG/ceph-crash-..."
    plugin_command "$ceph_shell $CEPH crash ls" > "$CEPHLOG"/ceph-crash-ls 2>&1
    {
        plugin_command "$ceph_shell $CEPH crash stat" 2>&1
        $ceph_shell $CEPH crash ls 2>/dev/null |
            cut -d' ' -f1 |
            while read crashid; do
                plugin_command "$ceph_shell $CEPH crash info $crashid" 2>&1
            done
    } > "$CEPHLOG"/ceph-crash-info
}

#############################################################
# Collect advanced/admin debug information about a Ceph daemon, and log it into the appropriate
# directory. This information should then be the same for all backends
collect_info_from_daemon() {
    local daemon="$1" # e.g., "mon.b", "osd.5", "mds.b"
    local container_shell="$2" # e.g., "cephadm enter --name mon.b --" or "kubectl -n rook-ceph exec <pod> -- env -i"

    local logdir="$DAEMONLOG"/"$daemon"
    mkdir "$logdir"
    plugin_message "  Collecting information about daemon $daemon > $logdir"

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
