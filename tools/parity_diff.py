"""Compare the iOS and Android upload bodies from the shared parity scenario.

Each platform's parity test (iOS WireTests.testParityScenarioAndDeepLinkProperties, Android
TransportTest.parityScenarioAndDeepLinkProperties) writes its body to $SFERE_PARITY_DIR. This script
compares every Sfere-controlled key path, type and value per event. Platform context filled by the
base libraries (device, os, app, ...) is listed but not compared: it differs by design, and the
Android JVM tests run without Android's context plugin.

Usage: tools/parity.sh (runs both tests, then this), or python3 tools/parity_diff.py <dir with ios.json and android.json>
Exit code 1 when anything differs.
"""
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
def load(n):
    body = json.loads((d / f"{n}.json").read_text())
    return body, {(e.get("event") or e["type"]): e for e in body["batch"]}
def paths(o, pre=""):
    out = {}
    if isinstance(o, dict):
        for k, v in o.items(): out.update(paths(v, f"{pre}.{k}" if pre else k))
    elif isinstance(o, list):
        for v in o: out.update(paths(v, pre + "[]"))
    else:
        out[pre] = type(o).__name__.replace("int", "num").replace("float", "num")
    return out
differences = 0
ib, ie = load("ios"); ab, ae = load("android")
print("envelope keys  ios:", sorted(ib), " android:", sorted(ab))
print("events         ios:", sorted(ie), "\n               android:", sorted(ae))
# platform context the base libraries fill (device/os/app/...) differs by design and by test host
PLATFORM = ("context.device", "context.os", "context.app", "context.screen", "context.network",
            "context.locale", "context.timezone", "context.userAgent")
for name in sorted(set(ie) | set(ae)):
    if name not in ie or name not in ae:
        print(f"\n[{name}] only on", "ios" if name in ie else "android"); differences += 1; continue
    pi = {k: v for k, v in paths(ie[name]).items() if not k.startswith(PLATFORM)}
    pa = {k: v for k, v in paths(ae[name]).items() if not k.startswith(PLATFORM)}
    only_i, only_a = sorted(set(pi) - set(pa)), sorted(set(pa) - set(pi))
    types = sorted(k for k in set(pi) & set(pa) if pi[k] != pa[k])
    vals = []
    for path in ("properties", "context.campaign", "context.consent", "context.traits", "traits", "name", "userId"):
        cur_i, cur_a = ie[name], ae[name]
        for part in path.split("."):
            cur_i = cur_i.get(part) if isinstance(cur_i, dict) else None
            cur_a = cur_a.get(part) if isinstance(cur_a, dict) else None
        if isinstance(cur_i, dict) and isinstance(cur_a, dict):
            cur_i = {k: v for k, v in cur_i.items() if k != "sfere_dedup_id" or v == "order_1"}
            cur_a = {k: v for k, v in cur_a.items() if k != "sfere_dedup_id" or v == "order_1"}
        if cur_i != cur_a: vals.append((path, cur_i, cur_a))
    ci = sorted((ie[name].get("context") or {}).get("clientIds", {})); ca = sorted((ae[name].get("context") or {}).get("clientIds", {}))
    if ci != ca: vals.append(("context.clientIds keys", ci, ca))
    status = "same" if not (only_i or only_a or types or vals) else "DIFF"
    if status == "DIFF": differences += 1
    print(f"\n[{name}] {status}")
    for k in only_i: print("   only ios     ", k)
    for k in only_a: print("   only android ", k)
    for k in types: print("   type differs ", k, pi[k], pa[k])
    for p, a, b in vals: print("   value differs", p, "\n      ios:    ", a, "\n      android:", b)
print("\nplatform context keys  ios:", sorted({k.split('.')[1] for e in ie.values() for k in paths(e) if k.startswith(PLATFORM)}))
print("                       android:", sorted({k.split('.')[1] for e in ae.values() for k in paths(e) if k.startswith(PLATFORM)}))
sys.exit(1 if differences else 0)
