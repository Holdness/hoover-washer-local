#!/usr/bin/env python3
"""Read and decrypt a Candy/Hoover simply-Fi washer's status locally.

The encryption is a repeating-key XOR, sent as uppercase hex.

  * In Wi-Fi setup mode (washer is its own hotspot at 192.168.0.1) the key is the
    LAST 8 CHARACTERS of the hotspot name, e.g. WIFIWASHMACHINE-ab12 -> "INE-ab12".
  * Once provisioned onto your home network, the key is the 16-character key that
    was sent during provisioning (see candy_provision.py).

Usage:
    python candy_decode.py <host> <key>
    CANDY_HOST=192.168.1.50 CANDY_KEY=xxxxxxxxxxxxxxxx python candy_decode.py
"""
import json
import os
import sys
import urllib.request


def xor(key: bytes, data: bytes) -> bytes:
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def fetch(host: str, path: str) -> bytes:
    with urllib.request.urlopen(f"http://{host}{path}", timeout=5) as r:
        return r.read().strip()


def read_status(host: str, key: str):
    body = fetch(host, "/http-read.json?encrypted=1").decode("ascii").strip()
    if body.startswith("{"):          # plaintext reply (unencrypted model)
        return json.loads(body)
    return json.loads(xor(key.encode(), bytes.fromhex(body)))


if __name__ == "__main__":
    host = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CANDY_HOST")
    key = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("CANDY_KEY")
    if not host or not key:
        sys.exit("usage: candy_decode.py <host> <key>   (or set CANDY_HOST and CANDY_KEY)")
    print(json.dumps(read_status(host, key), indent=2))
