#!/bin/bash

export KUBECTL_ROOK="$KUBECTL --namespace $ROOK_NAMESPACE"

resource_overview() {
    local namespace="$1"
    local resource="$2"
    section_header "$resource overview"
    plugin_command "$KUBECTL --namespace=$namespace get $resource" 2>&1
}

resource_detail() {
    local namespace="$1"
    local resource="$2"
    section_header "$resource detail"
    # --output=json and --output=yaml have more information than 'kubectl describe'
    # output is cluttered, but sometimes critical information is missing from 'kubectl describe'
    # --output=json has same info as --output=yaml
    # use --output=json so that 'jq' can be used to inspect logs afterwards if desired
    plugin_command "$KUBECTL --namespace=$namespace get $resource --output=json" 2>&1
}

resource_overview_and_detail() {
    local namespace="$1"
    local resource="$2"
    resource_overview "$namespace" "$resource"
    resource_detail "$namespace" "$resource"
}

get_pod_phase() {
  local namespace="$1"
  local pod="$2"
  if ! pod_json="$($KUBECTL --namespace="$namespace" get pod "$pod" --output=json)"; then
      return $? # error
  fi
  echo "$pod_json" | jq -r '.status.phase'
  return 0
}

get_pod_containers() {
    local namespace="$1"
    local pod="$2"
    if ! pod_json="$($KUBECTL --namespace="$namespace" get pod "$pod" --output=json)"; then
        return $? # error
    fi
    # print init containers in init order followed by app containers
    if [[ "$(echo "$pod_json" | jq -r '.spec.initContainers | length')" -gt 0 ]]; then
        echo "$pod_json" | jq -r '.spec.initContainers[].name'
    fi
    echo "$pod_json" | jq -r '.spec.containers[].name'
    return 0
}

pod_logs() {
    local namespace="$1"
    local pod="$2"
    # First output the phase of the pod, which is useful contextual information if the pod is
    # not in the assumed Running state.
    section_header "pod status phase"
    { echo -n "pod status phase: " ; get_pod_phase "$namespace" "$pod" ; } 2>&1
    if ! containers="$(get_pod_containers "$namespace" "$pod")"; then
        return $? # error
    fi
    # Log previous logs first since the likely workflow will be to read the logs bottom-up. Thus, we
    # want the bottommost log to be the most useful, which in almost all cases will be the single
    # application pod.
    section_header "previous logs for pod $pod"
    for container in $containers; do
        plugin_command "$KUBECTL --namespace=$namespace logs $pod --container=$container --previous" 2>&1
    done
    section_header "logs for pod $pod"
    for container in $containers; do
        plugin_command "$KUBECTL --namespace=$namespace logs $pod --container=$container" 2>&1
    done
}


#
#   Collector-helper
# The below helpers allow the supportutils plugin to run 'ceph' CLI commands against a running Rook
# cluster.
#
COLLECTOR_MANIFEST="$ROOKLOG"/collector-helper.yaml
COLLECTOR_LOG="$ROOKLOG"/collector-helper

# COLLECTOR_SHELL connects into the collector-helper. This will only work after
# 'start_collector_helper' is successful and stops working after 'stop_collector_helper' is called.
export COLLECTOR_SHELL="${KUBECTL_ROOK:?} exec -t deploy/supportutils-ses-collector-helper --"

start_collector_helper() {
    local ROOK_NAMESPACE="$1"
    local ROOK_IMAGE="$2"
    # we normally wouldn't check the vars so intently, but it's really important that the manifest
    # file gets created properly immediately below
    if [[ -z "$ROOK_NAMESPACE" ]]; then
        print_error "Arg 1: ROOK_NAMESPACE is not set"
        return 1
    fi
    if [[ -z "$ROOK_IMAGE" ]]; then
        print_error "Arg 2: ROOK_IMAGE is not set"
        return 1
    fi
    # collector manifest file is based directly on the Rook toolbox
    # if the toolbox changes functionality (rarely) this must also change
    cat > "$COLLECTOR_MANIFEST" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: supportutils-ses-collector-helper
  # namespace was set by supportutils-ses-plugin
  namespace: ${ROOK_NAMESPACE}
  labels:
    app: supportutils-ses-collector-helper
spec:
  replicas: 1
  selector:
    matchLabels:
      app: supportutils-ses-collector-helper
  template:
    metadata:
      labels:
        app: supportutils-ses-collector-helper
    spec:
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: supportutils-ses-collector-helper
        # image was set by supportutils-ses-plugin
        image: ${ROOK_IMAGE}
        command: ["/tini"]
        args: ["-g", "--", "/usr/local/bin/toolbox.sh"]
        imagePullPolicy: IfNotPresent
        env:
          - name: ROOK_CEPH_USERNAME
            valueFrom:
              secretKeyRef:
                name: rook-ceph-mon
                key: ceph-username
          - name: ROOK_CEPH_SECRET
            valueFrom:
              secretKeyRef:
                name: rook-ceph-mon
                key: ceph-secret
        volumeMounts:
          - mountPath: /etc/ceph
            name: ceph-config
          - name: mon-endpoint-volume
            mountPath: /etc/rook
      volumes:
        - name: mon-endpoint-volume
          configMap:
            name: rook-ceph-mon-endpoints
            items:
            - key: data
              path: mon-endpoints
        - name: ceph-config
          emptyDir: {}
      tolerations:
        - key: "node.kubernetes.io/unreachable"
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 5
EOF
    plugin_command "$KUBECTL apply --filename='$COLLECTOR_MANIFEST'" >> "$COLLECTOR_LOG" 2>&1
    # wait for collector helper pod and container to be running and exec'able
    # usually starts in 2 seconds in testing
    TIMEOUT=${COLLECTOR_HELPER_TIMEOUT:-15} # seconds
    start=$SECONDS
    until plugin_command "$COLLECTOR_SHELL rook version" >> "$COLLECTOR_LOG" 2>&1; do
        if [[ $((SECONDS - start)) -gt $TIMEOUT ]]; then
            echo "ERROR: failed to start supportutils collector helper within $TIMEOUT seconds"
            dump_collector_helper_info
            stop_collector_helper
            return 1
        fi
    done
}

dump_collector_helper_info() {
  selector="--selector 'app=supportutils-ses-collector-helper'"
  {
    plugin_command "$KUBECTL_ROOK get pod $selector --output=yaml" 2>&1
    plugin_command "$KUBECTL_ROOK get replicaset $selector --output=yaml" 2>&1
    plugin_command "$KUBECTL_ROOK get deployment supportutils-ses-collector-helper --output=yaml" 2>&1
  } >> "$COLLECTOR_LOG"
}

stop_collector_helper() {
  plugin_command "$KUBECTL delete --filename='$COLLECTOR_MANIFEST'" >> "$COLLECTOR_LOG" 2>&1
}
