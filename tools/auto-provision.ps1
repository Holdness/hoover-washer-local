# Auto-provision the Hoover washer onto home Wi-Fi, beating the flaky/short AP window.
# START THIS FIRST, then trigger the washer's Wi-Fi setup mode - the script waits for
# the AP to appear, then connects + sends the config with no human delay.
#
#   powershell -ExecutionPolicy Bypass -File auto-provision.ps1 -HomeSsid "MyHomeWiFi" -WasherSsid WIFIWASHMACHINE-ab12 -Key <16 chars>
#
param(
    [Parameter(Mandatory)][string]$HomeSsid,     # your home Wi-Fi name
    [Parameter(Mandatory)][string]$WasherSsid,   # the washer's setup hotspot, e.g. WIFIWASHMACHINE-ab12
    [Parameter(Mandatory)][string]$Key,          # 16-char alphanumeric key the washer will adopt
    [string]$ConfigKey  = '',                    # setup key; defaults to the last 8 chars of WasherSsid
    [int]   $Mode       = 3,                     # NTW_MODE: 3=WPA/WPA2, 2=WEP, 0=open
    [int]   $WaitApMinutes = 5
)

if (-not $ConfigKey) { $ConfigKey = $WasherSsid.Substring($WasherSsid.Length - 8) }
$gateway = '192.168.0.1'
$OutDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log     = Join-Path $OutDir ("provision-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Log($m){ $l="[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$m; Write-Host $l; Add-Content $Log $l }

# Home Wi-Fi password (typed once, not stored)
$sec = Read-Host "Home Wi-Fi password for $HomeSsid" -AsSecureString
$HomePass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))

if ($HomePass -match '[&=]') { Log "WARNING: password contains & or = which will break the payload." }

# Build the encrypted data param (repeating-XOR with ConfigKey, UPPERCASE hex)
$payload = "NTW_MODE=$Mode&SSID=$HomeSsid&PASSWORD=$HomePass&ENCRYPT_KEY=$Key"
$kb = [Text.Encoding]::ASCII.GetBytes($ConfigKey)
$pb = [Text.Encoding]::ASCII.GetBytes($payload)
$data = -join (0..($pb.Length-1) | ForEach-Object { '{0:X2}' -f ($pb[$_] -bxor $kb[$_ % $kb.Length]) })
$url = "http://$gateway/http-config.json?encrypted=1&data=$data"
Log "Payload (pw hidden): NTW_MODE=$Mode&SSID=$HomeSsid&PASSWORD=****&ENCRYPT_KEY=$Key"
Log "Washer will adopt ENCRYPT_KEY = $Key"

# Force a real Wi-Fi scan (Windows otherwise only rescans occasionally while connected)
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class WlanScanner {
  [DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint v, IntPtr r, out uint nv, out IntPtr h);
  [DllImport("wlanapi.dll")] static extern int WlanEnumInterfaces(IntPtr h, IntPtr r, out IntPtr list);
  [DllImport("wlanapi.dll")] static extern int WlanScan(IntPtr h, ref Guid g, IntPtr ssid, IntPtr ie, IntPtr r);
  [DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr h, IntPtr r);
  [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
  public static void Scan() {
    uint nv; IntPtr h; if (WlanOpenHandle(2, IntPtr.Zero, out nv, out h) != 0) return;
    IntPtr list; if (WlanEnumInterfaces(h, IntPtr.Zero, out list) == 0) {
      int n = Marshal.ReadInt32(list);
      for (int i = 0; i < n; i++) {
        IntPtr p = new IntPtr(list.ToInt64() + 8 + i * 532);
        Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
        WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
      }
      WlanFreeMemory(list);
    }
    WlanCloseHandle(h, IntPtr.Zero);
  }
}
"@
netsh wlan delete profile name="$WasherSsid" 2>$null | Out-Null
# 1. Wait for the washer AP to appear (you trigger setup mode now)
Log "Waiting up to $WaitApMinutes min for $WasherSsid to appear - put the washer in setup mode now..."
$deadline = (Get-Date).AddMinutes($WaitApMinutes); $seen = $false
while ((Get-Date) -lt $deadline) {
    try {
        [WlanScanner]::Scan(); Start-Sleep -Milliseconds 2500
    } catch {}
    if ((netsh wlan show networks) -match [regex]::Escape($WasherSsid)) { $seen=$true; break }
    Start-Sleep -Seconds 3
}
if (-not $seen) { Log "AP never appeared. Power-cycle the washer at the mains and retry."; exit 1 }
Log "AP is up - connecting immediately."

# 2. Connect (create a manual profile so Windows won't roam away)
$xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
 <name>$WasherSsid</name>
 <SSIDConfig><SSID><name>$WasherSsid</name></SSID></SSIDConfig>
 <connectionType>ESS</connectionType><connectionMode>manual</connectionMode>
 <MSM><security><authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption></security></MSM>
</WLANProfile>
"@
$pf = Join-Path $env:TEMP 'washer-prov.xml'; Set-Content $pf $xml -Encoding UTF8
netsh wlan add profile filename="$pf" user=current | Out-Null
$homeAuto = [bool]((netsh wlan show profile name="$HomeSsid") -match 'Connection mode\s+:\s+Connect automatically')
netsh wlan set profileparameter name="$HomeSsid" connectionmode=manual | Out-Null   # stop Windows jumping back home
netsh wlan connect name="$WasherSsid" | Out-Null

try {
    # 3. Fast loop: whenever we're on the washer AP, fire the config request every ~0.5s.
    #    (The module reboots every ~8-10s, so we must hit the brief window it's serving.)
    $ok=$false; $staticSet=$false; $lastState=''; $tries=0
    $deadline2 = (Get-Date).AddSeconds(150)
    while ((Get-Date) -lt $deadline2) {
        $wi   = netsh wlan show interfaces
        $ssid = ''; $st = ''
        $m = $wi | Select-String '^\s+SSID\s+:\s+(.+)$'  | Select-Object -First 1; if ($m) { $ssid = $m.Matches[0].Groups[1].Value.Trim() }
        $m = $wi | Select-String '^\s+State\s+:\s+(.+)$' | Select-Object -First 1; if ($m) { $st   = $m.Matches[0].Groups[1].Value.Trim() }
        $ip   = (Get-NetIPAddress -InterfaceAlias 'Wi-Fi' -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -join ','
        $state = "state=$st ssid=$ssid ip=$ip"
        if ($state -ne $lastState) { Log $state; $lastState=$state }

        if ($ssid -ne $WasherSsid) {
            if ($st -notmatch 'associating|authenticating') { netsh wlan connect name="$WasherSsid" | Out-Null }
            Start-Sleep -Milliseconds 700; continue
        }
        $tries++
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Timeout = 1500; $req.ReadWriteTimeout = 1500; $req.KeepAlive = $false
            $resp = $req.GetResponse()
            $body = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd(); $resp.Close()
            Log ("SENT after $tries tries. Response HTTP {0}: {1}" -f [int]$resp.StatusCode, $body.Trim())
            Log "Reconnecting home; give the washer ~60s to join $HomeSsid."
            $ok=$true; break
        } catch {
            $msg = $_.Exception.InnerException.Message; if (-not $msg) { $msg = $_.Exception.Message }
            if ($msg -ne $lastErr) { Log "try $tries : $msg"; $lastErr = $msg }
        }
        Start-Sleep -Milliseconds 400
    }
    if (-not $ok) { Log "Never got through after $tries tries. Last: $lastState" }
}
catch { Log "SCRIPT ERROR line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" }
finally {
    if ($homeAuto) { netsh wlan set profileparameter name="$HomeSsid" connectionmode=auto | Out-Null }
    if ($staticSet) { netsh interface ip set address name="Wi-Fi" dhcp | Out-Null }
    netsh wlan disconnect | Out-Null
    netsh wlan connect name="$HomeSsid" | Out-Null
    netsh wlan delete profile name="$WasherSsid" | Out-Null
    Remove-Item $pf -ErrorAction SilentlyContinue
    for ($i=1;$i -le 15;$i++){ Start-Sleep 2; if (Test-Connection 8.8.8.8 -Count 1 -Quiet){break} }
    Log "Back online. Log saved: $Log"
}
