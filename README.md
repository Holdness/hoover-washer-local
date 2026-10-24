# Hoover washer local control

Local Home Assistant control of a Hoover washer-dryer that the hOn app no longer
supports. Everything runs on the home network; no Hoover or Candy cloud is involved.

Tested on one machine: a **Hoover HBDOS695TAMCE-80** washer-dryer with the
simply-Fi Wi-Fi module. Other Candy/Hoover simply-Fi appliances use the same local
API, but their programme numbers and options differ, so expect to adapt things.

## What it does

From a Home Assistant dashboard:

- live status: idle, running, delayed, finished, time left, programme, temperature, spin
- start any programme remotely, with temperature, spin, soil level ("how dirty"),
  wash & dry, and a delayed start of 1–24 hours
- stop a wash or cancel a delay
- with an energy-monitoring smart plug: kWh and cost per wash, and a "finished"
  notification such as *The washing has finished 🧺 1h 16m, 0.56 kWh, £0.04*

The washer's dial must be on **ONE Fi EXTRA** for any remote start.

## How it works

The washer runs a small web API on its Wi-Fi module. Requests and replies are
XOR-encrypted with a key. The full details are in [docs/protocol.md](docs/protocol.md).

1. **Provisioning.** The old app put the washer on your Wi-Fi by sending it one
   encrypted request containing your network name, password and a new 16-character
   key. The scripts in `tools/` send that request themselves, so you choose the key.
2. **Status.** The community [Candy integration](https://github.com/ofalvai/home-assistant-candy)
   (installed through HACS) reads the washer's status using that key.
3. **Control.** Home Assistant has no built-in way to send commands, so a
   `rest_command` encrypts each command in a template and sends it. Two scripts
   build the commands from dashboard choices and retry, because the washer's Wi-Fi
   module only handles one connection at a time.

## Setting it up

You need Python 3 on a PC with Wi-Fi, and Home Assistant with HACS.

### 1. Put the washer on your Wi-Fi

1. Put the washer into setup mode: dial on any programme except OFF, then hold
   **Temperature + Start/Pause** until the display shows `rr`. A hotspot called
   `WIFIWASHMACHINE-xxxx` appears.
2. Join that hotspot from the PC, wait about 15 seconds, then run:

   ```
   python tools/candy_provision.py --ap-ssid WIFIWASHMACHINE-xxxx --ssid "Your home Wi-Fi" --send
   ```

   It asks for your Wi-Fi password, generates a 16-character key, saves it to
   `washer_new_key.txt` and prints it. **Keep that key.**
3. The washer drops its hotspot and joins your network. Ours took about nine
   minutes. Find its address in your router (a DHCP reservation helps), then check it:

   ```
   python tools/candy_decode.py <washer ip> <key>
   ```

If the hotspot keeps disappearing before the request gets through, which ours did,
`tools/auto-provision.ps1` (Windows) waits for the hotspot and fires the request
repeatedly. `tools/phone_provision.py` makes QR codes so a phone can send it instead.

### 2. Status in Home Assistant

Install **Candy** from HACS (ofalvai/home-assistant-candy) and add the washer with
its address. It found our 16-character key on its own.

### 3. Remote control

1. Add [home-assistant/rest_command.yaml](home-assistant/rest_command.yaml) to
   `configuration.yaml`, with your key and the washer's address, and restart.
2. Create the helpers in [home-assistant/helpers.yaml](home-assistant/helpers.yaml).
3. Add the scripts in [home-assistant/scripts.yaml](home-assistant/scripts.yaml).
4. Create a dashboard from [home-assistant/dashboard.yaml](home-assistant/dashboard.yaml).

In the scripts and dashboard, replace `sensor.bathroom_washing_machine` with your
Candy sensor's name and `notify.mobile_app_your_phone` with your phone. If your
dial differs from ours, map it with `tools/map_programs.py` and update the
programme table at the top of `washer_start`.

### 4. Energy tracking (optional)

Plug the washer into an energy-monitoring smart plug, then add
[home-assistant/energy_automation.yaml](home-assistant/energy_automation.yaml).
It detects each wash from the plug's power, so it keeps working when the washer's
own Wi-Fi locks up after a delayed start. The file explains the sensors it needs.

## Things to know

- **Standby.** About five minutes after going idle the washer sleeps and refuses
  commands. The start script checks first and tells you to turn the dial off and
  back to ONE Fi EXTRA.
- **Spin.** Only speeds lower than the programme's default are sent. Asking for a
  higher one left our washer beeping and off the network until it was switched off
  and on.
- **Delayed starts.** When a delayed start begins running, the washer's Wi-Fi stops
  responding until it is power-cycled. The wash runs normally, but Home Assistant
  loses sight of it. The plug-based energy tracking covers this.
- **Soil level** "Lightly soiled" cut Cottons to 20 minutes on our machine.

## Tools

| Script | Use |
|---|---|
| `candy_provision.py` | Build and send the Wi-Fi setup request. |
| `auto-provision.ps1` | Windows: wait for the setup hotspot and fire the request repeatedly. |
| `phone_provision.py` | QR codes so a phone can send the setup request. |
| `candy_decode.py` | Read and decrypt the washer's status. |
| `candy_command.py` | Send start, stop or any raw command from the command line. |
| `map_programs.py` | Print each dial position's programme number and defaults. |
| `probe-washer.ps1` | Windows: early network probe of the setup hotspot. |
| `program_map.json` | Our dial mapping. |

The scripts take the washer's address and key as arguments or from the
`CANDY_HOST` and `CANDY_KEY` environment variables. Nothing is stored in the code.

## Credits and disclaimer

- Status comes from [ofalvai/home-assistant-candy](https://github.com/ofalvai/home-assistant-candy).
- The command formats were worked out by reading how the Hoover Wizard Android app
  talks to the washer. No part of that app is included here.

This project isn't affiliated with or endorsed by Hoover, Candy or Haier. It sends
commands to a machine that uses water, heat and a spinning drum: use it at your own
risk, and don't start a wash you can't keep an eye on.

MIT licence.
