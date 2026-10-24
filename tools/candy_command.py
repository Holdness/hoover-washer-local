#!/usr/bin/env python3
"""Send a remote-control command to a Candy/Hoover simply-Fi washer.

The dial MUST be on ONE Fi EXTRA for a remote start to be accepted.

  python candy_command.py status
  python candy_command.py start <prog> [--temp T] [--spin RPM] [--delay HOURS] [--soil 1-3] [--dry 1-8]
  python candy_command.py stop  <prog>
  python candy_command.py raw "Write=1&..."

<prog> is the 'Pr' number from program_map.json (e.g. 9 = Drain & Spin).
Washer address and key come from --host/--key or the CANDY_HOST/CANDY_KEY
environment variables. See docs/protocol.md for what each parameter does.
"""
import argparse
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROGS = {int(k): v for k, v in json.load(open(os.path.join(HERE, "program_map.json"))).items()
         if not k.startswith("_")}


class Washer:
    def __init__(self, host: str, key: str):
        self.host, self.key = host, key.encode()

    def _xor(self, b: bytes) -> bytes:
        return bytes(x ^ self.key[i % len(self.key)] for i, x in enumerate(b))

    def get(self, path: str) -> str:
        # The Wi-Fi module serves one connection at a time, so be patient.
        with urllib.request.urlopen(f"http://{self.host}/{path}", timeout=30) as r:
            body = r.read().decode("ascii", "replace").strip()
        try:
            return self._xor(bytes.fromhex(body)).decode("utf-8", "replace")
        except ValueError:
            return body                                   # plain (unencrypted) reply

    def send(self, params: str) -> str:
        print(">>", params)
        return self.get("http-write.json?encrypted=1&data=" + self._xor(params.encode()).hex().upper())

    def status(self) -> dict:
        return json.loads(self.get("http-read.json?encrypted=1"))["statusLavatrice"]


def start_params(prog, temp=None, spin_rpm=None, delay=0, soil=None, dry=None) -> str:
    d = PROGS[prog]
    p = f"Write=1&Pa=0&Sel=0&PrNm={prog}"
    p += f"&DelMd=1&DelVl={delay}" if delay else "&StSt=1"
    if temp is not None and temp != d["temp"]:
        p += f"&TmpTgt={temp}&TmpDf={d['temp']}"
    if spin_rpm is not None:
        if spin_rpm // 100 > d["spin"]:
            # A spin above the programme default left our washer beeping and offline.
            sys.exit(f"spin {spin_rpm} is above this programme's default of {d['spin'] * 100}; refusing.")
        if spin_rpm // 100 != d["spin"]:
            p += f"&SpdTgt={spin_rpm // 100}&SpdDef={d['spin']}"
    if soil:
        p += f"&SLevTgt={soil}"
    if dry:
        p += f"&Stm=0&Dry={dry}"
    return p + "&OptMsk=0"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["start", "stop", "status", "raw"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--host", default=os.environ.get("CANDY_HOST"))
    ap.add_argument("--key", default=os.environ.get("CANDY_KEY"))
    ap.add_argument("--temp", type=int)
    ap.add_argument("--spin", type=int, help="rpm, e.g. 800 (lower than the default only)")
    ap.add_argument("--delay", type=int, default=0, help="delayed start, whole hours 1-24")
    ap.add_argument("--soil", type=int, choices=[1, 2, 3], help="1 lightly soiled, 2 normal, 3 very dirty")
    ap.add_argument("--dry", type=int, choices=range(1, 9), metavar="1-8",
                    help="1 extra, 2 iron, 3 cupboard, 4 cool down, 5-8 = 120/90/60/30 min")
    a = ap.parse_args()
    if not a.host or not a.key:
        sys.exit("washer address and key needed: --host/--key or CANDY_HOST/CANDY_KEY")
    w = Washer(a.host, a.key)

    if a.cmd == "status":
        print(json.dumps(w.status(), indent=2))
        return
    if a.cmd == "raw":
        print("<<", w.send(a.arg))
        return
    prog = int(a.arg)
    if prog not in PROGS:
        sys.exit(f"unknown programme {prog}; see program_map.json")
    if a.cmd == "start":
        s = w.status()
        if s.get("Pr") != "15":
            sys.exit(f"Dial is on programme {s.get('Pr')}, not ONE Fi EXTRA (15); refusing to start.")
        print("<<", w.send(start_params(prog, a.temp, a.spin, a.delay, a.soil, a.dry)))
    else:
        print("<<", w.send(f"Write=1&StSt=0&DelMd=0&PrNm={prog}"))


if __name__ == "__main__":
    main()
