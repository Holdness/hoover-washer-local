#!/usr/bin/env python3
"""Provision a Candy/Hoover simply-Fi washer onto your home Wi-Fi WITHOUT the app.

Reverse-engineered from the Hoover Wizard APK (it.candyhoover.core):
  ConnectionManager.configureAppliance() builds a LinkedHashMap
     NTW_MODE, SSID, PASSWORD, ENCRYPT_KEY
  -> CandyNetworkUtility.urlWithParams()  => "k=v&k=v..."
  -> CandySecurityUtility.xorEncrypt(params, key)   (repeating-XOR + UPPERCASE hex)
     where key = calculateEncriptionKeyForConf(APSSID) = last 8 chars of the AP SSID
  -> GET http://<ip>/http-config.json?encrypted=1&data=<hex>

  NTW_MODE:  2 = WEP,  3 = WPA/WPA2  (from the enrollment radio buttons)
  ENCRYPT_KEY: the app sends a fresh random 16-char alphanumeric key
               (calculateEncriptionKey) that the appliance ADOPTS for all future
               encrypted comms. We choose our own so we know it afterwards.

Usage (run while connected to the washer's own setup hotspot, e.g. WIFIWASHMACHINE-ab12):
    python candy_provision.py --ap-ssid WIFIWASHMACHINE-ab12 --ssid "MyHomeWiFi" --mode 3
        (prompts for the Wi-Fi password; generates + saves a 16-char key;
         prints the URL. Add --send to actually fire it.)
"""
import argparse, secrets, string, sys, os, time, socket, getpass, urllib.request, urllib.error

HOST_DEFAULT       = "192.168.0.1"

def xor_hex(plaintext: str, key: str) -> str:
    kb = key.encode()
    return "".join(f"{b ^ kb[i % len(kb)]:02X}" for i, b in enumerate(plaintext.encode()))

def clean(s: str) -> str:
    return s.replace('"', "")            # cleanSSID/cleanPassword strip quotes

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ssid", required=True, help="YOUR home Wi-Fi name")
    ap.add_argument("--password", help="home Wi-Fi password (omit to be prompted)")
    ap.add_argument("--mode", type=int, default=3, help="NTW_MODE: 3=WPA/WPA2 (default), 2=WEP, 0=open")
    ap.add_argument("--key", help="16-char alphanumeric ENCRYPT_KEY (omit to auto-generate)")
    ap.add_argument("--host", default=HOST_DEFAULT)
    ap.add_argument("--ap-ssid", help="the washer's setup hotspot name; its last 8 characters are the setup key")
    ap.add_argument("--config-key", help="setup key, if you'd rather give it directly")
    ap.add_argument("--send", action="store_true", help="actually send the request")
    a = ap.parse_args()

    config_key = a.config_key or (a.ap_ssid[-8:] if a.ap_ssid else None)
    if not config_key:
        sys.exit("give --ap-ssid (the washer's hotspot name) or --config-key")
    pw = a.password if a.password is not None else getpass.getpass("Home Wi-Fi password: ")
    key = a.key or "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
    if len(key) != 16 or not key.isalnum():
        print("WARNING: ENCRYPT_KEY should be 16 alphanumeric chars for HA compatibility.")

    ssid, pw = clean(a.ssid), clean(pw)
    for label, val in (("SSID", ssid), ("PASSWORD", pw)):
        if "&" in val or "=" in val:
            print(f"WARNING: {label} contains & or = which may break the unescaped payload.")

    payload = f"NTW_MODE={a.mode}&SSID={ssid}&PASSWORD={pw}&ENCRYPT_KEY={key}"
    data = xor_hex(payload, config_key)
    url = f"http://{a.host}/http-config.json?encrypted=1&data={data}"

    keyfile = os.path.join(os.path.dirname(os.path.abspath(__file__)), "washer_new_key.txt")
    saved = None
    for target in (keyfile, os.path.join(os.path.expanduser("~"), "washer_new_key.txt")):
        try:
            with open(target, "w") as f:
                f.write(key + "\n")
            saved = target
            break
        except OSError:
            continue
    where = f"saved to {saved}" if saved else "COULD NOT SAVE - copy it down now!"
    print(f"\n=== ENCRYPT_KEY the washer will use afterwards ({where}) ===")
    print("   ", key)
    print("\n=== payload (before encryption) ===")
    print("   ", payload.replace(pw, "*" * len(pw)))   # don't echo the real password
    print("\n=== provisioning URL ===")
    print("   ", url)

    if a.send:
        print("\nSending...")
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                print("HTTP", r.status, "->", r.read().decode("ascii", "replace").strip())
            print("Sent. Watch the washer's Wi-Fi light; give it ~30-60s to join, then look for")
            print("its new IP in your router's DHCP list. Read it with:")
            print(f"   python candy_decode.py <that-ip> {key}")
        except urllib.error.URLError as e:
            print("Send failed:", e, "\n(Are you connected to the washer's setup hotspot?)")
    else:
        print("\n(dry run - re-run with --send while on the washer AP to fire it)")

if __name__ == "__main__":
    main()
