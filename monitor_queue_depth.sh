#!/bin/bash

# 1. Discover pods (safely)
POD_DATA=$(kubectl get pods -l app=triton-recml -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{" "}{.metadata.labels.gpu}{"\n"}{end}' | head -n 8)

# Parse into arrays
names=()
ips=()
types=()
while read -r name ip gpu; do
    if [ -n "$name" ]; then
        names+=("$name")
        ips+=("$ip")
        types+=("$gpu")
    fi
done <<< "$POD_DATA"

num_pods=${#names[@]}

if [ "$num_pods" -eq 0 ]; then
    echo "No Triton pods found."
    exit 1
fi

# Print Header
printf "%-9s" "Time"
for i in "${!names[@]}"; do
    # Shorten name to the last 5 chars of the hash for brevity
    short_name=$(echo "${names[$i]}" | rev | cut -d'-' -f1 | rev)
    printf " | %-12s" "$short_name(${types[$i]})"
done
echo ""

# Print Separator
printf -- "---------"
for i in $(seq 1 $num_pods); do printf -- "+--------------"; done
echo ""

# 2. Monitor Loop
while true; do
    TIME=$(date +%H:%M:%S)
    
    # Construct a single command to fetch all metrics at once
    cmd=""
    for ip in "${ips[@]}"; do
        if [ -n "$ip" ]; then
            cmd+="q=\$(curl -s http://$ip:8002/metrics | awk '/nv_inference_pending_request_count{/ {print \$2}'); if [ -z \"\$q\" ]; then echo -n '0 '; else echo -n \"\$q \"; fi; "
        else
            cmd+="echo -n '0 '; "
        fi
    done

    # Execute and parse
    results=$(kubectl exec perf-client -- bash -c "$cmd" 2>/dev/null)
    
    printf "%-9s" "$TIME"
    read -a queues <<< "$results"
    
    for i in "${!ips[@]}"; do
        val=${queues[$i]}
        if [ -z "$val" ]; then val="0"; fi
        printf " | %-12s" "$val"
    done
    echo ""
    
    sleep 2
done
