import subprocess
import time
import re
import sys

def get_running_pods(label):
    cmd = "kubectl get pods -l " + label + " --field-selector=status.phase=Running -o custom-columns=NAME:.metadata.name --no-headers"
    try:
        result = subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode().strip().split('\n')
        return [p for p in result if p]
    except Exception:
        return []

def get_metrics(pod):
    try:
        cmd = "kubectl exec " + pod + " -- curl -s localhost:8002/metrics 2>/dev/null"
        output = subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode()
        match = re.search(r'nv_inference_request_success\{model="recml-model",version="1"\} (\d+)', output)
        if match:
            return int(float(match.group(1)))
    except Exception:
        pass
    return 0

print("Time     | L4 Succ | G4 Succ | L4 Diff | G4 Diff | L4 Pods | G4 Pods", flush=True)
print("-" * 75, flush=True)

prev_l4 = 0
prev_g4 = 0

while True:
    l4_pods = get_running_pods("gpu=l4")
    g4_pods = get_running_pods("gpu=g4")

    curr_l4 = sum(get_metrics(p) for p in l4_pods)
    curr_g4 = sum(get_metrics(p) for p in g4_pods)
    
    delta_l4 = curr_l4 - prev_l4 if prev_l4 > 0 else 0
    delta_g4 = curr_g4 - prev_g4 if prev_g4 > 0 else 0
    
    timestamp = time.strftime("%H:%M:%S")
    print(f"{timestamp} | {curr_l4:7d} | {curr_g4:7d} | {delta_l4:7d} | {delta_g4:7d} | {len(l4_pods):7d} | {len(g4_pods):7d}", flush=True)
    
    prev_l4 = curr_l4
    prev_g4 = curr_g4
    time.sleep(5)
