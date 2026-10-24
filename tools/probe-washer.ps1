# Probe the Hoover washer's setup access point (read-only), then reconnect to home Wi-Fi.
# Usage:  powershell -ExecutionPolicy Bypass -File probe-washer.ps1 [-Key <wifi password if needed>]
param(
    [Parameter(Mandatory)][string]$WasherSsid,   # e.g. WIFIWASHMACHINE-ab12
    [Parameter(Mandatory)][string]$HomeProfile,  # your home Wi-Fi profile name, to reconnect afterwards
    [string]$Key = ''
)

$OutDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Log = Join-Path $OutDir "probe-results-$Stamp.txt"

function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $Log -Value $line -Encoding UTF8
}
function LogBlock($title, $text) {
    Log "===== $title ====="
    Add-Content -Path $Log -Value ($text | Out-String) -Encoding UTF8
}

# Ask the Wi-Fi adapter for a fresh scan (netsh only shows cached results)
Add-Type -Namespace Wlan -Name Api -MemberDefinition @'
[DllImport("wlanapi.dll")] public static extern uint WlanOpenHandle(uint v, IntPtr r, out uint nv, out IntPtr h);
[DllImport("wlanapi.dll")] public static extern uint WlanCloseHandle(IntPtr h, IntPtr r);
[DllImport("wlanapi.dll")] public static extern uint WlanScan(IntPtr h, ref Guid g, IntPtr ssid, IntPtr ie, IntPtr r);
'@
function Invoke-WifiScan {
    try {
        $guid = [Guid](Get-NetAdapter -Name 'Wi-Fi').InterfaceGuid
        $nv = 0; $h = [IntPtr]::Zero
        [Wlan.Api]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$nv, [ref]$h) | Out-Null
        [Wlan.Api]::WlanScan($h, [ref]$guid, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        [Wlan.Api]::WlanCloseHandle($h, [IntPtr]::Zero) | Out-Null
    } catch { Log "Scan request failed: $_" }
}

Log "Probe starting. Results file: $Log"

# 1. Wait for the washer's network to appear
$found = $false
for ($i = 1; $i -le 12; $i++) {
    Invoke-WifiScan
    Start-Sleep -Seconds 5
    $nets = netsh wlan show networks mode=bssid | Out-String
    if ($nets -match [regex]::Escape($WasherSsid)) { $found = $true; break }
    Log "Washer network not visible yet (attempt $i/12)..."
}
if (-not $found) {
    Log "Could not see $WasherSsid. Put the washer in Wi-Fi setup mode and run again."
    exit 1
}
$idx = $nets.IndexOf($WasherSsid)
LogBlock "Washer network details" $nets.Substring($idx, [Math]::Min(900, $nets.Length - $idx))

# 2. Create a temporary Wi-Fi profile (manual connect only, so Windows never auto-joins it)
if ($Key) {
    $security = "<authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption><sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>$Key</keyMaterial></sharedKey>"
} else {
    $security = "<authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption>"
}
$profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$WasherSsid</name>
  <SSIDConfig><SSID><name>$WasherSsid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security>$security</security></MSM>
</WLANProfile>
"@
$profilePath = Join-Path $env:TEMP 'washer-profile.xml'
Set-Content -Path $profilePath -Value $profileXml -Encoding UTF8

try {
    Log (netsh wlan add profile filename="$profilePath" user=current | Out-String).Trim()
    Log "Connecting to $WasherSsid - this PC goes offline now."
    Log (netsh wlan connect name="$WasherSsid" | Out-String).Trim()

    # 3. Wait for an IP address from the washer
    $gateway = $null
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 2
        $cfg = Get-NetIPConfiguration -InterfaceAlias 'Wi-Fi' -ErrorAction SilentlyContinue
        $ssidNow = (netsh wlan show interfaces | Select-String '^\s+SSID\s+:' | Out-String)
        if ($ssidNow -match [regex]::Escape($WasherSsid) -and $cfg.IPv4DefaultGateway) {
            $gateway = $cfg.IPv4DefaultGateway.NextHop; break
        }
    }
    LogBlock "Interface status" (netsh wlan show interfaces)
    LogBlock "IP configuration" (ipconfig /all)
    if (-not $gateway) {
        # Some devices don't hand out a gateway; fall back to guessing from our own address
        $myIp = (Get-NetIPAddress -InterfaceAlias 'Wi-Fi' -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        Log "No gateway received. Our IP: $myIp"
        if ($myIp -and $myIp -notlike '169.254.*') { $gateway = ($myIp -replace '\.\d+$', '.1') }
    }
    if (-not $gateway) { throw "Never got a usable IP address from the washer." }
    Log "Washer (gateway) address: $gateway"
    LogBlock "ARP table" (arp -a)

    # We've learned all we can from UDP discovery: nothing answers the usual ESP
    # probe strings, and hammering that ESP8266 with a dozen unanswered UDP packets
    # actually WEDGES it (last run the gateway went unresponsive right after the
    # volley). So that whole section is gone. The real prize is the Candy/Hoover
    # simply-Fi JSON API on TCP 80 - go straight at it while the module is fresh.
    $bcast = ($gateway -replace '\.\d+$', '.255')
    function Heartbeat($tag) {
        $alive = Test-Connection $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
        Log "Heartbeat [$tag]: gateway $gateway $(if ($alive) { 'ALIVE' } else { 'NOT RESPONDING' })"
        return $alive
    }

    # 4. Wait for the port-80 web server to bind (it takes ~10-15s after joining;
    #    probe every 3s for up to 40s instead of blindly sleeping). No UDP traffic.
    Log "Waiting for the Candy API on TCP 80 to come up..."
    $webUp = $false
    for ($i = 1; $i -le 14; $i++) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            if ($c.ConnectAsync($gateway, 80).Wait(600) -and $c.Connected) { $webUp = $true }
        } catch {} finally { $c.Close() }
        if ($webUp) { Log "Port 80 open (attempt $i of 14)."; break }
        Start-Sleep -Seconds 3
    }
    Heartbeat "port80-check" | Out-Null

    # 5. Enumerate the Candy simply-Fi API. The 'Encrypted' header + the
    #    {"response":"BAD REQUEST"} we saw are its fingerprint. These endpoints
    #    tell us whether this unit reads in clear text (encrypted=0) or needs a
    #    key, and reveal the Wi-Fi provisioning page. Read-only GETs only.
    if ($webUp) {
        $apiPaths = @(
            '/http-read.json?encrypted=0',
            '/http-read.json?encrypted=1',
            '/http-read.json?encrypted=0&cmd=1',
            '/http-read.json',
            '/http-getStatistics.json?encrypted=0',
            '/http-getStatistics.json?encrypted=1',
            '/http-getStatistics.json',
            '/http-write.json?encrypted=0',
            '/http-cmd.json?encrypted=0',
            '/wifiSetup.html',
            '/wifi.html',
            '/wifiscan.html',
            '/index.html',
            '/status.html',
            '/appliance.json',
            '/device.json'
        )
        foreach ($ap in $apiPaths) {
            $url = "http://$gateway$ap"
            try {
                $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
                $body = $r.Content; if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) + '...[truncated]' }
                LogBlock "GET $ap -> $($r.StatusCode)" (($r.Headers | Out-String) + "`n" + $body)
            } catch {
                $code = $_.Exception.Response.StatusCode.value__
                Log "GET $ap -> $(if ($code) { "HTTP $code" } else { $_.Exception.Message })"
            }
        }
        Heartbeat "after-api" | Out-Null
    } else {
        Log "Port 80 never came up in the window - module may be wedged or slow."
    }

    # 6. One short, passive 55555 listen at the very end (we've already decoded the
    #    beacon as MAC+IP; keep it only to reconfirm the module is still announcing).
    $u = New-Object System.Net.Sockets.UdpClient
    try {
        $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $u.Client.Bind((New-Object System.Net.IPEndPoint([Net.IPAddress]::Any, 55555)))
        $u.Client.ReceiveTimeout = 12000
        $remote = New-Object System.Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $data = $u.Receive([ref]$remote)
        Log "55555 beacon still seen from $($remote.Address) ($($data.Length) bytes)."
    } catch { Log "55555: no beacon in a 12s window." } finally { $u.Close() }
}
catch {
    Log "ERROR: $_"
}
finally {
    # 7. Always go back home and remove the temporary profile
    Log "Reconnecting to $HomeProfile..."
    netsh wlan disconnect | Out-Null
    netsh wlan connect name="$HomeProfile" | Out-Null
    netsh wlan delete profile name="$WasherSsid" | Out-Null
    Remove-Item $profilePath -ErrorAction SilentlyContinue
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 2
        if (Test-Connection 8.8.8.8 -Count 1 -Quiet) { break }
    }
    Log "Back online: $(Test-Connection 8.8.8.8 -Count 1 -Quiet)"
    Log "Done. Results saved to $Log"
}
