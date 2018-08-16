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
NS=jwtest

# Set post resize capacity for PVs
CAPACITY=15Gi

selector=`kubectl get statefulset --namespace=$NS $SS -o go-template='--selector={{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//'`
pods=(`kubectl get pod --namespace=$NS $selector -o go-template='{{range .items}}{{.metadata.name}} {{end}}'`)
pvcs=(`kubectl get pod --namespace=$NS $selector -o go-template='{{range .items}}{{range .spec.volumes}}{{if eq .name "data"}}{{.persistentVolumeClaim.claimName}} {{end}}{{end}}{{end}}'`)

for pvc in ${pvcs[@]}; do
    echo "patch pvc $pvc"
    kubectl patch pvc --namespace=$NS $pvc --patch='{"spec":{"resources":{"requests":{"storage":"'$CAPACITY'"}}}}'
done

echo "scale down ss $SS"
kubectl scale statefulset --namespace=$NS $SS --replicas=0

echo ""
while [[ ! -z `kubectl get pod --namespace=$NS $selector -o go-template='{{range .items}}{{.metadata.name}} {{end}}'` ]]; do
    terminating=(`kubectl get pod --namespace=$NS $selector | awk '/Terminating/{print($1)}'`)
    for pod in ${terminating[@]}; do
        echo -ne "\e[0K\rterminating pod $pod"
        pid=`kubectl exec --namespace=$NS $pod -- ps aux | awk '/pre-stop-hook.sh/{print($2)}'`
        if [[ ! -z $pid ]]; then
            echo -n ", killing hook with pid $pid"
            kubectl exec --namespace=$NS $pod -- kill $pid
            echo " - killed"
        fi
        sleep 2
    done
done

declare -A finished_pvc
echo -n "finished_pvc:0  pvcs:${#pvcs[@]} $statuses"
while [[ ${#finished_pvc[@]} != ${#pvcs[@]} ]]; do
    statuses=''
    for pvc in ${pvcs[@]}; do
        status=$(kubectl --namespace=$NS get pvc $pvc --output=go-template --template='{{range .status.conditions}}{{.type}} {{end}}')
        statuses="$statuses $pvc:[$status]"
        if [[ $status == *FileSystemResizePending* ]]; then
            finished_pvc[$pvc]=1
        fi
        sleep 1
    done
    echo -ne "\e[0K\rfinished_pvc:${#finished_pvc[@]} pvcs:${#pvcs[@]} - $statuses"
done
echo ""

echo "scale back to ${#pods[@]}"
kubectl scale statefulset --namespace=$NS $SS --replicas=${#pods[@]}

running_pods=()
echo -n "running_pods:0  expect:${#pods[@]}"
while [[ ${#running_pods[@]} != ${#pods[@]} ]]; do
    phases=`kubectl get pod --namespace=$NS $selector -o go-template='{{range .items}}{{.metadata.name}}:[{{.status.phase}}] {{end}}'`
    running_pods=(`kubectl get pod --namespace=$NS $selector -o go-template='{{range .items}}{{if eq .status.phase "Running"}}{{.metadata.name}} {{end}}{{end}}'`)
    echo -ne "\e[0K\rrunning_pods:${#running_pods[@]} expect:${#pods[@]} - $phases"
done
echo ""

kubectl get pvc --namespace=$NS ${pvcs[@]}
