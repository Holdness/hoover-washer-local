#!/usr/bin/env python3
"""Poll the washer and print a line whenever programme/temp/spin changes.

Turn the dial slowly through every position while this runs to map your own
machine's programme numbers and defaults (see program_map.json).

    CANDY_HOST=192.168.1.50 CANDY_KEY=xxxxxxxxxxxxxxxx python map_programs.py [seconds]
"""
import json
import os
import sys
import time
import urllib.request

HOST, KEY = os.environ.get("CANDY_HOST"), os.environ.get("CANDY_KEY")
FIELDS = ("Pr", "Temp", "SpinSp", "SLevel", "MachMd", "RemTime", "Opt1", "Steam", "DryT")


def read():
    with urllib.request.urlopen(f"http://{HOST}/http-read.json?encrypted=1", timeout=4) as r:
        b = bytes.fromhex(r.read().decode().strip())
    k = KEY.encode()
    return json.loads(bytes(x ^ k[i % len(k)] for i, x in enumerate(b)))["statusLavatrice"]


if __name__ == "__main__":
    if not HOST or not KEY:
        sys.exit("set CANDY_HOST and CANDY_KEY")
    last, fails = None, 0
    end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 1500)
    while time.time() < end:
        try:
            s = read()
            fails = 0
            cur = tuple(s.get(f) for f in FIELDS)
            if cur != last:
                print(time.strftime("%H:%M:%S"), " ".join(f"{f}={v}" for f, v in zip(FIELDS, cur)), flush=True)
                last = cur
        except Exception as e:
            fails += 1
            if fails == 5:
                print(time.strftime("%H:%M:%S"), "washer not answering:", e, flush=True)
        time.sleep(2)
