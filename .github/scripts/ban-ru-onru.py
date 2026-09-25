#!/usr/bin/env python3
"""Build rules/category-ban-ru-onru.mrs: the part of category-ban-ru that is hosted on Russian IPs.

Why: category-ban-ru (RKN registry, ~23k .ru/.su/.рф domains) matters for routing only where a
blocked domain would otherwise fall into a DIRECT rule: in a typical config everything unmatched
already goes to the proxy (MATCH), and a domain on a foreign IP never hits `geoip-for-ru`. So a
memory-constrained client (iOS Network Extension) needs only the domains that resolve to IPs from
geoip-for-ru-v4 — about a tenth of the list (a third of the list does not even resolve any more).

How: every entry is resolved (A) over DNS-over-HTTPS JSON (Cloudflare, Google as fallback), the
answers are checked against rules/geoip-for-ru-v4.mrs, "+.x" entries without an A record are
retried as "www.x". Entries that failed to resolve (timeout/SERVFAIL, not NXDOMAIN) are kept if
they were in the previous build. Stdlib only; mihomo (on PATH) decodes inputs and compiles output.

Guards (the previous .mrs is kept and the run is marked with a warning):
  - fewer than MIN_RESOLVED_PCT % of the entries got an answer (NOERROR/NXDOMAIN) -> DNS trouble;
  - the result has fewer than MIN_ENTRIES or more than MAX_ENTRIES entries;
  - the result shrank below MIN_RATIO % of the previous build;
  - mihomo printed a warning while compiling, or the output does not read back.

usage: ban-ru-onru.py [--src rules/category-ban-ru.mrs] [--geoip rules/geoip-for-ru-v4.mrs]
                      [--out rules/category-ban-ru-onru.mrs] [--workers 48] [--limit N]
"""
import argparse
import bisect
import http.client
import ipaddress
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

MIN_RESOLVED_PCT = int(os.environ.get("MIN_RESOLVED_PCT", "90"))
MIN_ENTRIES = int(os.environ.get("MIN_ENTRIES", "200"))
MAX_ENTRIES = int(os.environ.get("MAX_ENTRIES", "15000"))
MIN_RATIO = int(os.environ.get("MIN_RATIO", "60"))
PROVIDERS = [("cloudflare-dns.com", "/dns-query"), ("dns.google", "/resolve")]
MIHOMO = os.environ.get("MIHOMO_BIN", "mihomo")


def warn(msg):
    print(f"  ⚠ {msg}")
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::warning title=ban-ru-onru::{msg}")


def summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n")


def mihomo_decode(behavior, mrs):
    """rules/*.mrs -> list of lines (mihomo convert-ruleset <behavior> mrs)."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out.txt")
        subprocess.run([MIHOMO, "convert-ruleset", behavior, "mrs", mrs, out],
                       check=True, capture_output=True)
        with open(out, encoding="utf-8") as f:
            return [line.strip() for line in f if line.strip()]


def ranges_from_cidrs(cidrs):
    rs = []
    for c in cidrs:
        n = ipaddress.ip_network(c, strict=False)
        if n.version == 4:
            rs.append((int(n.network_address), int(n.broadcast_address)))
    rs.sort()
    merged = []
    for a, b in rs:
        if merged and a <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


class Resolver:
    """DoH JSON A lookups; one persistent HTTPS connection per thread and provider."""

    def __init__(self):
        self.local = threading.local()

    def _conn(self, host):
        conns = getattr(self.local, "conns", None)
        if conns is None:
            conns = self.local.conns = {}
        c = conns.get(host)
        if c is None:
            c = conns[host] = http.client.HTTPSConnection(host, timeout=10)
        return c

    def _drop(self, host):
        c = getattr(self.local, "conns", {}).pop(host, None)
        if c is not None:
            c.close()

    def query(self, name):
        """-> ('ok', [ips]) | ('nx', []) | ('err', [])"""
        qname = urllib.parse.quote(name.encode("idna").decode("ascii"))
        for attempt in range(4):
            host, path = PROVIDERS[attempt % len(PROVIDERS)]
            try:
                c = self._conn(host)
                c.request("GET", f"{path}?name={qname}&type=A",
                          headers={"accept": "application/dns-json", "user-agent": "mihomo-rule-set"})
                r = c.getresponse()
                body = r.read()
                if r.status == 429 or r.status >= 500:
                    time.sleep(0.5 * (attempt + 1))
                    continue
                if r.status != 200:
                    continue
                j = json.loads(body)
            except (OSError, http.client.HTTPException, ValueError):
                self._drop(host)
                time.sleep(0.3 * (attempt + 1))
                continue
            st = j.get("Status")
            if st == 3:
                return "nx", []
            if st == 0:
                return "ok", [a["data"] for a in j.get("Answer") or [] if a.get("type") == 1]
            # SERVFAIL / REFUSED: try the other provider
        return "err", []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="rules/category-ban-ru.mrs")
    ap.add_argument("--geoip", default="rules/geoip-for-ru-v4.mrs")
    ap.add_argument("--out", default="rules/category-ban-ru-onru.mrs")
    ap.add_argument("--workers", type=int, default=48)
    ap.add_argument("--limit", type=int, default=0, help="test: resolve only the first N entries")
    a = ap.parse_args()

    for f in (a.src, a.geoip):
        if not os.path.isfile(f):
            warn(f"{f} is missing (run 'Generate mihomo Rules' first), nothing built")
            return 0
    entries = sorted(set(mihomo_decode("domain", a.src)))
    ru = ranges_from_cidrs(mihomo_decode("ipcidr", a.geoip))
    starts = [x for x, _ in ru]
    prev = set(mihomo_decode("domain", a.out)) if os.path.isfile(a.out) else set()
    if a.limit:
        entries = entries[:a.limit]
    print(f"entries {len(entries)}, geoip-for-ru ranges {len(ru)}, previous build {len(prev)}")

    def in_ru(ip):
        try:
            x = int(ipaddress.IPv4Address(ip))
        except ValueError:
            return False
        i = bisect.bisect_right(starts, x) - 1
        return i >= 0 and ru[i][0] <= x <= ru[i][1]

    res = Resolver()

    def job(entry):
        name = entry[2:] if entry.startswith("+.") else entry.lstrip(".")
        st, ips = res.query(name)
        if entry.startswith("+.") and (st == "nx" or (st == "ok" and not ips)):
            st2, ips2 = res.query("www." + name)
            if st2 == "ok" and ips2:
                st, ips = st2, ips2
        return entry, st, ips

    t0 = time.time()
    with ThreadPoolExecutor(a.workers) as ex:
        results = list(ex.map(job, entries))
    # second, gentler pass for transient failures (rate limits, timeouts)
    retry = [i for i, (_, st, _) in enumerate(results) if st == "err"]
    if retry:
        time.sleep(5)
        with ThreadPoolExecutor(max(1, a.workers // 6)) as ex:
            for i, r in zip(retry, ex.map(job, [results[i][0] for i in retry])):
                results[i] = r
        print(f"retried {len(retry)} failed lookups")
    dt = time.time() - t0
    n_ok = sum(1 for _, st, ips in results if st == "ok" and ips)
    n_noa = sum(1 for _, st, ips in results if st == "ok" and not ips)
    n_nx = sum(1 for _, st, _ in results if st == "nx")
    n_err = sum(1 for _, st, _ in results if st == "err")
    onru = {e for e, st, ips in results if st == "ok" and any(in_ru(ip) for ip in ips)}
    sticky = {e for e, st, _ in results if st == "err" and e in prev}
    out = sorted(onru | sticky)
    answered = 100 * (len(results) - n_err) / max(1, len(results))
    stat = (f"resolved {len(results)} in {dt:.0f}s: A {n_ok}, no A {n_noa}, NXDOMAIN {n_nx}, errors {n_err} "
            f"({answered:.1f}% answered); on Russian IPs {len(onru)}, kept from previous (errors) {len(sticky)} "
            f"-> {len(out)} entries (previous {len(prev)})")
    print(stat)
    summary("### category-ban-ru-onru\n\n" + stat)

    if a.limit:
        print("test run (--limit): nothing written")
        return 0
    if answered < MIN_RESOLVED_PCT:
        warn(f"only {answered:.1f}% answered (< {MIN_RESOLVED_PCT}%), DNS trouble? kept previous {a.out}")
        return 0
    if not MIN_ENTRIES <= len(out) <= MAX_ENTRIES:
        warn(f"{len(out)} entries outside {MIN_ENTRIES}..{MAX_ENTRIES}, kept previous {a.out}")
        return 0
    if prev and len(out) * 100 < len(prev) * MIN_RATIO:
        warn(f"shrank {len(prev)} -> {len(out)} (< {MIN_RATIO}%), kept previous {a.out}")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "list.yaml")
        dst = os.path.join(tmp, "out.mrs")
        with open(src, "w", encoding="utf-8") as f:
            f.write("payload:\n" + "".join(f"  - '{e}'\n" for e in out))
        p = subprocess.run([MIHOMO, "convert-ruleset", "domain", "yaml", src, dst],
                           capture_output=True, text=True)
        log = (p.stdout or "") + (p.stderr or "")
        if p.returncode != 0 or "level=warning" in log:
            warn(f"compile failed or mihomo rejected entries: {log.strip()[-300:]}; kept previous {a.out}")
            return 0
        back = mihomo_decode("domain", dst)
        if len(back) != len(out):
            warn(f"read-back {len(back)} != {len(out)} entries, kept previous {a.out}")
            return 0
        os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
        shutil.move(dst, a.out + ".tmp")   # tmp dir may be another filesystem
        os.replace(a.out + ".tmp", a.out)
    print(f"  ✅ {a.out}: {len(out)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
