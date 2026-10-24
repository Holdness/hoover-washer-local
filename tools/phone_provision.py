#!/usr/bin/env python3
"""Build the washer's provisioning URL and show it as QR codes for a PHONE to scan.

Why: the PC loses its link to the washer's flaky setup AP within seconds. A phone
joins faster and can fire the URL the moment it connects.

    python phone_provision.py --ap-ssid WIFIWASHMACHINE-ab12 --ssid "MyHomeWiFi" [--key 16CHARKEY]

Prompts for the home Wi-Fi password (not echoed, not saved), then writes
phone-provision.html next to this script and opens it. That page contains the
(lightly-scrambled) password - DELETE IT when done (this script offers to).
"""
import argparse, getpass, os, secrets, string, webbrowser, html
from candy_provision import xor_hex, clean

ap = argparse.ArgumentParser()
ap.add_argument("--ap-ssid", required=True, help="the washer's setup hotspot name, e.g. WIFIWASHMACHINE-ab12")
ap.add_argument("--ssid", required=True, help="your home Wi-Fi name")
ap.add_argument("--mode", type=int, default=3, help="NTW_MODE: 3=WPA/WPA2 (default), 2=WEP, 0=open")
ap.add_argument("--key", help="16-char key the washer will adopt (omit to generate one)")
args = ap.parse_args()

AP_SSID    = args.ap_ssid
HOME_SSID  = args.ssid
MODE       = args.mode
KEY        = args.key or "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
CONFIG_KEY = AP_SSID[-8:]           # last 8 chars of the setup hotspot name
HOST       = "192.168.0.1"

here = os.path.dirname(os.path.abspath(__file__))
out  = os.path.join(here, "phone-provision.html")

pw = clean(getpass.getpass(f"Home Wi-Fi password for {HOME_SSID}: "))
if "&" in pw or "=" in pw:
    print("WARNING: password contains & or = which will break the payload.")

payload  = f"NTW_MODE={MODE}&SSID={HOME_SSID}&PASSWORD={pw}&ENCRYPT_KEY={KEY}"
cfg_url  = f"http://{HOST}/http-config.json?encrypted=1&data={xor_hex(payload, CONFIG_KEY)}"
test_url = f"http://{HOST}/http-read.json?encrypted=1"

page = f"""<!doctype html><html><head><meta charset="utf-8"><title>Washer phone setup</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>body{{font-family:Segoe UI,sans-serif;max-width:900px;margin:24px auto;padding:0 16px;background:#fff;color:#111}}
.row{{display:flex;gap:40px;flex-wrap:wrap}} .box{{flex:1;min-width:300px}} .qr{{padding:16px;background:#fff;display:inline-block}}
code{{word-break:break-all;font-size:12px}} ol li{{margin:6px 0}}</style></head><body>
<h1>Washer phone setup</h1>
<ol>
<li>Phone: turn <b>mobile data OFF</b> (otherwise it may ignore the washer's no-internet hotspot).</li>
<li>Power-cycle the washer at the wall (30s), then put it into Wi-Fi setup mode.</li>
<li>Phone: join <b>{html.escape(AP_SSID)}</b>. If it says "no internet", choose <b>Stay connected</b>.</li>
<li>Optional: scan <b>QR 1</b>. A page of hex gibberish = the washer is ready. Nothing loading = not ready yet, retry in a few seconds.</li>
<li>Scan <b>QR 2</b> and open it. Screenshot whatever the phone shows.</li>
<li>Wait about a minute, then look for the washer on your home network. Delete this file afterwards.</li>
</ol>
<div class="row">
 <div class="box"><h2>QR 1 - test (safe)</h2><div class="qr" id="q1"></div><p><code>{html.escape(test_url)}</code></p></div>
 <div class="box"><h2>QR 2 - send Wi-Fi details</h2><div class="qr" id="q2"></div></div>
</div>
<script>
new QRCode(document.getElementById('q1'),{{text:{test_url!r},width:260,height:260,correctLevel:QRCode.CorrectLevel.M}});
new QRCode(document.getElementById('q2'),{{text:{cfg_url!r},width:340,height:340,correctLevel:QRCode.CorrectLevel.L}});
</script></body></html>"""

with open(out, "w", encoding="utf-8") as f:
    f.write(page)
print(f"Written {out} - opening it now.")
print(f"The washer will adopt key: {KEY}  (keep this - Home Assistant needs it)")
webbrowser.open("file:///" + out.replace("\\", "/"))

input("\nPress Enter when you're finished to DELETE the page (it contains the scrambled password)...")
try:
    os.remove(out); print("Deleted.")
except OSError as e:
    print("Could not delete:", e)
