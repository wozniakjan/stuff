#!/bin/bash

# K8 1.11 doesn't support online pvc resize for Cinder. Offline resize
# requires taking down the pod which in case of ES is a bit tricky. It
# has preStop lifecycle hook defined that moves around the data to
# other, still available ES nodes. This is not required neither desired
# because after the resize, we spin up the ES pods back on the same nodes
# using the same PVs.

# This could be at some point solved
# https://github.com/kubernetes/kubernetes/issues/59343

# meanwhile this script can automate killing the preStop hook and scaling
# up the PVCs. Also elasticsearch operator will probably handle that in
# the future.

set -e

# Set StatefulSet name
SS=jw5-pvc-debug

# Set post resize capacity for PVs
CAPACITY=3Gi

selector=(`kubectl get statefulset $SS -o go-template='{{range $k, $v := .spec.selector.matchLabels}}--selector={{$k}}={{$v}} {{end}}'`)
pods=(`kubectl get pod $selector -o go-template='{{range .items}}{{.metadata.name}} {{end}}'`)
pvcs=(`kubectl get pod $selector -o go-template='{{range .items}}{{range .spec.volumes}}{{if eq .name "data"}}{{.persistentVolumeClaim.claimName}} {{end}}{{end}}{{end}}'`)

for pvc in ${pvcs[@]}; do
    echo "patch pvc $pvc"
    kubectl patch pvc $pvc --patch='{"spec":{"resources":{"requests":{"storage":"'$CAPACITY'"}}}}'
done

echo "scale down ss $SS"
kubectl scale statefulset $SS --replicas=0

echo "killing a pod ${pods[@]}"
kubectl delete pod ${pods[@]} --grace-period=0
# for each existing pod
#   if in terminating status
#     if exec to the pod
#       while ! kill preStop hook
#       mark as killed
#     else
#       mark as killed

declare -A finished_pvc
while [[ ${#finished_pvc[@]} != ${#pvcs[@]} ]]; do
    for pvc in ${pvcs[@]}; do
        status=$(kubectl get pvc $pvc --output=go-template --template='{{range .status.conditions}}{{.type}} {{end}}')
        echo "status in $pvc - [$status]"
        if [[ $status == *FileSystemResizePending* ]]; then
            finished_pvc[$pvc]=1
        fi
        sleep 1
    done
    echo "finished_pvc:${#finished_pvc[@]}  pvcs:${#pvcs[@]}"
done

echo "scale back to ${#pods[@]}"
kubectl scale statefulset $SS --replicas=${#pods[@]}

running_pods=()
while [[ ${#running_pods[@]} != ${#pods[@]} ]]; do
    running_pods=(`kubectl get pod $selector -o go-template='{{range .items}}{{if eq .status.phase "Running"}}{{.metadata.name}} {{end}}{{end}}'`)
    echo "running_pods:${#running_pods[@]}  expect:${#pods[@]}"
    sleep 1
done

kubectl get pvc ${pvcs[@]}
