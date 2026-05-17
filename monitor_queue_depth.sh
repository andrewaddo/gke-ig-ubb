#!/bin/bash

echo "=========================================================================="
echo "Legend:"
echo "  Q : Current Queue Depth (Pending Requests waiting in Triton)"
echo "  R : Total Routed (+Requests sent to this pod since last tick)"
echo "  S : Successes (+Requests completed successfully since last tick)"
echo "  F : Failures (+Requests REJECTED due to timeout since last tick)"
echo "=========================================================================="
echo ""

PREV_POD_DATA=""

while true; do
    TIME=$(date +%H:%M:%S)
    
    # 1. Discover pods dynamically
    POD_DATA=$(kubectl get pods --field-selector=status.phase=Running -l 'app=triton-recml,gpu in (l4, g4)' -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{" "}{.metadata.labels.gpu}{"\n"}{end}' | sort | head -n 8)
    
    if [ "$POD_DATA" != "$PREV_POD_DATA" ]; then
        # Parse into arrays
        names=()
        ips=()
        types=()
        prev_counts=()
        prev_failures=()
        
        while read -r name ip gpu; do
            if [ -n "$name" ]; then
                names+=("$name")
                ips+=("$ip")
                types+=("$gpu")
                prev_counts+=(0)
                prev_failures+=(0)
            fi
        done <<< "$POD_DATA"
        
        num_pods=${#names[@]}
        
        if [ "$num_pods" -eq 0 ]; then
            printf "%-9s | No Triton pods found. Waiting...\n" "$TIME"
            PREV_POD_DATA="$POD_DATA"
            sleep 4
            continue
        fi
        
        echo ""
        echo "--- Pod topology changed. Updating monitoring view ---"
        
        # Print Header
        printf "%-9s" "Time"
        for i in "${!names[@]}"; do
            short_name=$(echo "${names[$i]}" | rev | cut -d'-' -f1 | rev)
            printf " | %-24s" "$short_name(${types[$i]})"
        done
        echo ""
        
        # Print Separator
        printf -- "---------"
        for i in $(seq 1 $num_pods); do printf -- "+-------------------------"; done
        echo ""
        
        first_run=true
        PREV_POD_DATA="$POD_DATA"
    fi

    # Construct a single command to fetch all metrics at once
    cmd=""
    for ip in "${ips[@]}"; do
        if [ -n "$ip" ]; then
            cmd+="m=\$(curl -s http://$ip:8080/metrics); "
            cmd+="q=\$(echo \"\$m\" | awk '/nv_inference_pending_request_count{/ {print \$2}'); "
            cmd+="s=\$(echo \"\$m\" | awk '/nv_inference_request_success{/ {print \$2}'); "
            cmd+="f_rej=\$(echo \"\$m\" | awk '/nv_inference_request_failure.*reason=\"REJECTED\"/ {print \$2}'); "
            cmd+="f_can=\$(echo \"\$m\" | awk '/nv_inference_request_failure.*reason=\"CANCELED\"/ {print \$2}'); "
            cmd+="f=\$((\${f_rej:-0} + \${f_can:-0})); "
            cmd+="echo -n \"\${q:-0} \${s:-0} \${f:-0} \"; "
        else
            cmd+="echo -n \"0 0 0 \"; "
        fi
    done

    # Execute and parse
    results=$(kubectl exec perf-client -- bash -c "$cmd" 2>/dev/null)
    if [ -z "$results" ]; then
        printf "%-9s | Error fetching metrics from perf-client. Check pod status.\n" "$TIME"
        sleep 4
        continue
    fi
    read -a raw_data <<< "$results"
    
    printf "%-9s" "$TIME"
    
    for i in "${!ips[@]}"; do
        q_idx=$((i * 3))
        s_idx=$((i * 3 + 1))
        f_idx=$((i * 3 + 2))
        
        curr_q=${raw_data[$q_idx]:-0}
        curr_s=${raw_data[$s_idx]:-0}
        curr_f=${raw_data[$f_idx]:-0}
        
        if [ "$first_run" = true ]; then
            delta_s=0
            delta_f=0
            delta_r=0
        else
            delta_s=$((curr_s - ${prev_counts[$i]}))
            delta_f=$((curr_f - ${prev_failures[$i]}))
            delta_r=$((delta_s + delta_f))
        fi
        
        # Format: Q:Depth S:+Success F:+Failed R:+Routed
        display_val="Q:$curr_q R:+$delta_r (S:+$delta_s F:+$delta_f)"
        printf " | %-24s" "$display_val"
        
        prev_counts[$i]=$curr_s
        prev_failures[$i]=$curr_f
    done
    echo ""
    
    first_run=false
    sleep 4
done
