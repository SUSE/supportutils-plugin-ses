#!/bin/bash

# Source this to import helper functions
# for the SUSE Enterprise Storage supportutils plugin


#############################################################
# Basic helper functions

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

# Make a symlink (link_file) pointing to a log file (target) within the current base log dir.
make_link() {
    local target="$1"
    local link_file="$2"
    # We know both the target and link will always include the base log dir, so as a compute
    # shortcut, always find path from link to target using the base as the point to '../' back to.
    base="${LOGCEPH%%+(/)}" # remove any/all trailing slashes from base
    link_dir="$(dirname "$link_file")" # dir-only components to link file
    link_rel_base="${link_dir#$base/}" # link file dir components relative to base
    # use 'dirname' to repeatedly strip one dir from the link path relative to base to determine how
    # many '../' are needed
    undepth=""
    until [[ "$link_rel_base" == "" ]] || [[ "$link_rel_base" == "." ]]; do
        undepth="../$undepth"
        link_rel_base="$(dirname "$link_rel_base")"
    done
    target_rel_base="${target#$base/}" # target dir components relative to base
    rel="${undepth}${target_rel_base}"
    ln --symbolic "$rel" "$link_file"
}


#############################################################
# Collect info from the Ceph CLI
collect_info_from_ceph_cli() {
    local ceph_shell="$1"

    # A command we are trying to call could hang or fail for myriad reasons, so add a timeout to all
    # calls. Use a multiplier of Ceph's connect timeout so that Ceph's timeout, if it occurs, is
    # sure to happen before the timeout command times out; this will give better error info.
    # Add --verbose option to timeout so output explicitly says it timed out.
    ceph_shell="$ceph_shell timeout --verbose $((CT * 2))"

    if ! plugin_command "$ceph_shell $CEPH --status" > "$LOGCEPH"/ceph-status 2>&1; then
        print_error "ceph --status failed (missing ceph.conf or admin keyring on host?)"
        return 1
    fi
    # For cephadm, none of the following will actually work without ceph.conf present on the host
    # and a valid keyring. Calling the above as a test gives us actual ceph status if everything is
    # working, or a helpful error message if not.

    plugin_message "Collecting basic Ceph cluster info > $LOGCEPH/..."

    plugin_command "$ceph_shell $CEPH versions" > "$LOGCEPH"/ceph-versions 2>&1
    plugin_command "$ceph_shell $CEPH health detail" > "$LOGCEPH"/ceph-health-detail 2>&1
    plugin_command "$ceph_shell $CEPH config dump" > "$LOGCEPH"/ceph-config-dump 2>&1
    plugin_command "$ceph_shell $CEPH mon dump" > "$LOGCEPH"/ceph-mon-dump 2>&1
    plugin_command "$ceph_shell $CEPH mgr dump" > "$LOGCEPH"/ceph-mgr-dump 2>&1
    plugin_command "$ceph_shell $CEPH osd tree" > "$LOGCEPH"/ceph-osd-tree 2>&1
    plugin_command "$ceph_shell $CEPH osd df tree" > "$LOGCEPH"/ceph-osd-df-tree 2>&1
    plugin_command "$ceph_shell $CEPH osd dump" > "$LOGCEPH"/ceph-osd-dump 2>&1
    plugin_command "$ceph_shell $CEPH osd pool autoscale-status" > "$LOGCEPH"/ceph-osd-pool-autoscale-status 2>&1
    plugin_command "$ceph_shell $CEPH osd pool ls detail" > "$LOGCEPH"/ceph-osd-pool-ls-detail 2>&1
    plugin_command "$ceph_shell $CEPH df detail" > "$LOGCEPH"/ceph-df-detail 2>&1
    plugin_command "$ceph_shell $CEPH fs dump -f json-pretty" > "$LOGCEPH"/ceph-fs-dump.json 2>&1
    plugin_command "$ceph_shell $CEPH fs dump" > "$LOGCEPH"/ceph-fs-dump 2>&1
    plugin_command "$ceph_shell $CEPH pg dump -f json-pretty" > "$LOGCEPH"/ceph-pg-dump.json 2>&1
    plugin_command "$ceph_shell $CEPH pg dump" > "$LOGCEPH"/ceph-pg-dump 2>&1
    plugin_command "$ceph_shell $CEPH auth list" 2>&1 |
        grep --invert-match 'installed auth entries' |
        sed "s/\(key:\) .*/\1 $CENSORED/g" > "$LOGCEPH"/ceph-auth-list
    # 'ceph report' does actually include the above information, but
    # in JSON format.  Since adding `ceph report`, the above commands
    # remain, because their output is easier to read in a hurry ;)
    plugin_command "$ceph_shell $CEPH report" > "$LOGCEPH"/ceph-report 2>&1
    plugin_command "$ceph_shell rados df" > "$LOGCEPH"/rados-df 2>&1
    plugin_command "$ceph_shell $CEPH telemetry status" > "$LOGCEPH"/ceph-telemetry-status 2>&1
    plugin_command "$ceph_shell $CEPH balancer status" > "$LOGCEPH"/ceph-balancer-status 2>&1

    # Orchestrator module
    plugin_message "Collecting Ceph orchestrator module info > $LOGCEPH/ceph-orch-status"
    {
        plugin_command "$ceph_shell $CEPH orch status" 2>&1
        plugin_command "$ceph_shell $CEPH cephadm get-ssh-config" 2>&1
        plugin_command "$ceph_shell $CEPH orch ls --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch host ls --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch ps --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch device ls --format yaml" 2>&1
        plugin_command "$ceph_shell $CEPH orch upgrade status" 2>&1
    } > "$LOGCEPH"/ceph-orch-status

    # RBD pool images
    plugin_message "Collecting info about RBD pool images > $LOGCEPH/rbd-images/<pool>/..."
    $ceph_shell ceph osd pool ls detail -f json-pretty 2>/dev/null |
        jq -r '.[] | select(.application_metadata.rbd != null) | .pool_name' |
        while read pool; do
            mkdir --parents "$LOGCEPH"/rbd-images
            plugin_command "$ceph_shell rbd ls $pool" > "$LOGCEPH/rbd-images/rbd-ls-$pool" 2>&1
            $ceph_shell rbd ls "$pool" 2>/dev/null |
                head -n "$RBD_INFO_MAX" |
                while read image; do
                    mkdir --parents "$LOGCEPH/rbd-images/pool-$pool" # only create this dir if the pool has images
                    plugin_command "$ceph_shell rbd -p $pool info $image" > "$LOGCEPH/rbd-images/pool-$pool/rbd-info-$image" 2>&1
                done
        done

    # RGW info if RGW running
    if $ceph_shell ceph osd pool ls detail 2>/dev/null | grep -q "application rgw"; then
        plugin_message "Collecting info about RADOS gateways (RGWs) > $LOGCEPH/radosgw-..."
        plugin_command "$ceph_shell radosgw-admin period get" > "$LOGCEPH"/radosgw-admin-period-get 2>&1
        plugin_command "$ceph_shell radosgw-admin bucket stats" > "$LOGCEPH"/radosgw-admin-bucket-stats 2>&1
        plugin_command "$ceph_shell radosgw-admin bucket limit check" >> "$LOGCEPH"/radosgw-admin-bucket-stats 2>&1
        plugin_command "$ceph_shell radosgw-admin metadata list bucket.instance" >> "$LOGCEPH"/radosgw-admin-bucket-stats 2>&1
    else
        plugin_message "(No RADOS gateways (RGWs) to collect info from)"
    fi

    # Inactive PGs
    IPGLOG="$LOGCEPH"/inactive-pgs
    plugin_message "Collecting info about inactive PGs > $IPGLOG/..."
    plugin_command "$ceph_shell $CEPH pg dump_stuck inactive" > "$LOGCEPH"/ceph-pg-dump_stuck-inactive 2>&1
    $ceph_shell $CEPH pg dump_stuck inactive -f json-pretty 2>/dev/null |
        jq -r '.stuck_pg_stats[].pgid' |
        head -n "$INACTIVE_PG_QUERY_MAX" |
        while read pg; do
            mkdir --parents "$IPGLOG" # only create this dir if there are inactive PGs to log
            plugin_command "$ceph_shell $CEPH pg $pg query" > "$IPGLOG/ceph-pg-$pg-query" 2>&1
        done

    # Crash collector
    plugin_message "Collecting crash dump info > $LOGCEPH/ceph-crash-..."
    plugin_command "$ceph_shell $CEPH crash ls" > "$LOGCEPH"/ceph-crash-ls 2>&1
    {
        plugin_command "$ceph_shell $CEPH crash stat" 2>&1
        $ceph_shell $CEPH crash ls 2>/dev/null |
            cut -d' ' -f1 |
            while read crashid; do
                plugin_command "$ceph_shell $CEPH crash info $crashid" 2>&1
            done
    } > "$LOGCEPH"/ceph-crash-info
}


#############################################################
# Collect advanced/admin debug info about a Ceph daemon, and log it into the appropriate
# directory. This info should then be the same for all backends
collect_info_from_daemon() {
    local daemon="$1" # e.g., "mon.b", "osd.5", "mds.b"
    local container_shell="$2" # e.g., "cephadm enter --name mon.b --" or "kubectl -n rook-ceph exec <pod> -- env -i"

    # Only create the daemon log dir if we are starting to collect info for any daemons
    mkdir --parents "$LOGDAEMON"

    local logdir="$LOGDAEMON"/"$daemon"
    mkdir "$logdir"
    plugin_message "    detailed info for daemon $daemon > $logdir/..."

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
