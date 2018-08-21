#!/bin/bash
set -e

if [[ -n ${VERBOSE+set} ]]; then
    set -v
fi

INDEX=${INDEX:-default}
QUERY_COUNT=${QUERY_COUNT:-1}
JSON_FIELD_COUNT=${JSON_FIELD_COUNT:-1}
BULK_SIZE=${BULK_SIZE:-0}
echo $POD_NAME

x () { 
    cat <(echo $POD_NAME) <(cat /dev/urandom|tr -dc 'a-zA-Z0-9'|fold -w 32|head -n 1) | sha1sum | awk '{print($1)}'
}

bulk () {
    for i in $(seq 1 $BULK_SIZE); do
        echo '{"index":{"_index":".job.loadtest.'$INDEX'","_type":"loadtest","_id":"'$(x)'"}'
        json
    done
}

json () {
    json_jq="jq -n -c --arg k1 \"`x`\""
    json_jq_tmp='{key1: $k1'
    for i in $(seq 2 $JSON_FIELD_COUNT); do
        json_jq="$json_jq --arg k$i \"`x`\""
        json_jq_tmp="$json_jq_tmp, key$i : \$k$i"
    done
    eval ${json_jq} \'${json_jq_tmp}'}'\'
}

capacity_msg='.*queue capacity.*'

for f in $(seq 0 $QUERY_COUNT); do
    echo "ES start time: `date +%s.%N`"
    if [[ $BULK_SIZE > 0 ]]; then
        bulk > json_file
        out=`curl -XPOST -H 'Content-Type: application/x-ndjson' http://elasticsearch-client.default:9200/_bulk --data-binary @json_file`
    else
        out=`curl -XPUT -H 'Content-Type: application/json' http://elasticsearch-client.default:9200/.job.loadtest.$INDEX/loadtest/$(x) -d "$(json)"`
    fi
    echo "ES end time: `date +%s.%N`"
    echo $out
    echo "*************"
done
