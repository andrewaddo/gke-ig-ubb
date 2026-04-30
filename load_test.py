import urllib.request
import json
import time
import concurrent.futures
import argparse

def send_request(url, payload):
    try:
        start_time = time.time()
        req = urllib.request.Request(url, data=json.dumps(payload).encode('utf-8'), headers={'Content-Type': 'application/json'}, method='POST')
        with urllib.request.urlopen(req, timeout=10) as resp:
            status_code = resp.getcode()
            latency = time.time() - start_time
            return status_code, latency
    except Exception as e:
        return str(e), 0

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gateway-ip", required=True)
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--delay", type=float, default=0.5)
    args = parser.parse_args()

    url = f"http://{args.gateway_ip}:80/v2/models/recml-model/infer"
    with open("input_data.json", "r") as f:
        payload = json.load(f)

    print(f"Starting load test against {url}")
    print(f"Concurrency: {args.concurrency}, Total Requests: {args.requests}, Delay between dispatch: {args.delay}s")

    start = time.time()
    success = 0
    errors = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = []
        for _ in range(args.requests):
            futures.append(executor.submit(send_request, url, payload))
            time.sleep(args.delay) # Introduce delay to slow down request rate
            
        for future in concurrent.futures.as_completed(futures):
            status, _ = future.result()
            if status == 200:
                success += 1
            else:
                errors += 1
                if errors < 10:
                    print(f"Error status: {status}")

    duration = time.time() - start
    print(f"Completed in {duration:.2f}s")
    print(f"Success: {success}, Errors: {errors}")
    print(f"Throughput: {args.requests/duration:.2f} req/s")

if __name__ == "__main__":
    main()
