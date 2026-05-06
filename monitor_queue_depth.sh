#!/bin/bash

# 1. Discover pods (safely)
POD_DATA=$(kubectl get pods -l app=triton-recml -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{" "}{.metadata.labels.gpu}{"\n"}{end}' | head -n 8)

# Parse into arrays
names=()
ips=()
types=()
prev_counts=()

while read -r name ip gpu; do
    if [ -n "$name" ]; then
        names+=("$name")
        ips+=("$ip")
        types+=("$gpu")
        prev_counts+=(0)
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
    short_name=$(echo "${names[$i]}" | rev | cut -d'-' -f1 | rev)
    printf " | %-15s" "$short_name(${types[$i]})"
done
echo ""

# Print Separator
printf -- "---------"
for i in $(seq 1 $num_pods); do printf -- "+----------------"; done
echo ""

# Initialize counts
first_run=true

# 2. Monitor Loop
while true; do
    TIME=$(date +%H:%M:%S)
    
    # Construct a single command to fetch all metrics at once
    # q = pending (queue), s = success (counter)
    cmd=""
    for ip in "${ips[@]}"; do
        if [ -n "$ip" ]; then
            cmd+="m=\$(curl -s http://$ip:8002/metrics); "
            cmd+="q=\$(echo \"\$m\" | awk '/nv_inference_pending_request_count{/ {print \$2}'); "
            cmd+="s=\$(echo \"\$m\" | awk '/nv_inference_request_success{/ {print \$2}'); "
            cmd+="echo -n \"\${q:-0} \${s:-0} \"; "
        else
            cmd+="echo -n \"0 0 \"; "
        fi
    done

    # Execute and parse
    results=$(kubectl exec perf-client -- bash -c "$cmd" 2>/dev/null)
    read -a raw_data <<< "$results"
    
    printf "%-9s" "$TIME"
    
    for i in "${!ips[@]}"; do
        q_idx=$((i * 2))
        s_idx=$((i * 2 + 1))
        
        curr_q=${raw_data[$q_idx]:-0}
        curr_s=${raw_data[$s_idx]:-0}
        
        if [ "$first_run" = true ]; then
            delta=0
        else
            delta=$((curr_s - ${prev_counts[$i]}))
        fi
        
        # Format: QueueDepth (+Processed)
        display_val="$curr_q (+$delta)"
        printf " | %-15s" "$display_val"
        
        prev_counts[$i]=$curr_s
    done
    echo ""
    
    first_run=false
    sleep 4
done
