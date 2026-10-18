"""Record one real Case Zero investigation of the demo ring as a replay file.

Usage: python record_replay.py <base_url> <out.jsonl> [seed] [as_of]
Writes one event per line, each stamped `_t` (seconds since the request), exactly as the SSE stream delivered it,
plus <out>.status.json with the final status and the full case report.
"""
import json
import sys
import time

import httpx

base, out_path = sys.argv[1].rstrip("/"), sys.argv[2]
seed = sys.argv[3] if len(sys.argv) > 3 else "acct_01070"
as_of = sys.argv[4] if len(sys.argv) > 4 else "2026-11-10T14:35:00"

t0 = time.monotonic()
events = []
with httpx.Client(timeout=httpx.Timeout(180.0)) as c:
    start = c.post(f"{base}/api/investigations", json={"seed": seed, "as_of": as_of})
    print("start", start.status_code, start.text[:200], flush=True)
    start.raise_for_status()
    info = start.json()
    with c.stream("GET", base + info["stream_url"]) as r:
        block = []
        for line in r.iter_lines():
            if line == "":
                data = "\n".join(l[6:] for l in block if l.startswith("data: "))
                block = []
                if data:
                    e = json.loads(data)
                    e["_t"] = round(time.monotonic() - t0, 2)
                    events.append(e)
                    extra = (e.get("call_id") or "") + " " + (e.get("name") or "")
                    print(f"{e['_t']:6.1f}s {e['type']:12s} {extra}", flush=True)
                    if e["type"] == "done":
                        break
            else:
                block.append(line)
    status = c.get(base + info["status_url"]).json()
    report = c.get(f"{base}/api/cases/{info['case_id']}")
    report_json = report.json() if report.status_code == 200 else {"http": report.status_code}

with open(out_path, "w", encoding="utf-8") as f:
    for e in events:
        f.write(json.dumps(e, ensure_ascii=False) + "\n")
with open(out_path + ".status.json", "w", encoding="utf-8") as f:
    json.dump({"info": info, "status": status, "report": report_json}, f, ensure_ascii=False, indent=1)
print("wall clock", round(time.monotonic() - t0, 1), "s; status", status.get("status"), "; events", len(events))
