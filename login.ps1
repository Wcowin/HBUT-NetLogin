<#
    HBUT-NetLogin - campus network (eportal) auto login
    https://github.com/  (put your repo url here)

    Usage:
        powershell -NoProfile -ExecutionPolicy Bypass -File login.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File login.ps1 -Force   # force re-login
        powershell -NoProfile -ExecutionPolicy Bypass -File login.ps1 -Poll    # short run for periodic checks

    Credentials are read from config.ps1 (not committed). See config.example.ps1
#>
param(
    [string]$Account,
    [string]$Password,
    [string]$PortalHost = '172.16.54.18',
    [string]$Service    = 'LT',            # LT = 联通, YD = 移动, DX = 电信, default = 校园网
    [string]$WlanSsid   = 'iHBUT',
    [string]$WlanAcName = 'logic',
    [string]$NasIp      = '10.253.0.17',
    [int]$PortalWaitSec = 180,
    [int]$MaxRetry      = 12,
    [int]$RetryInterval = 8,
    [switch]$Poll,
    [switch]$NoWifi,
    [switch]$Force
)

# ---- load local credentials (excluded by .gitignore) ----
$ConfigFile = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path $ConfigFile) { . $ConfigFile }

if ([string]::IsNullOrWhiteSpace($Account) -or [string]::IsNullOrWhiteSpace($Password)) {
    Write-Host 'ERROR: missing account/password.'
    Write-Host 'Copy config.example.ps1 to config.ps1 and fill in your student id and password.'
    exit 1
}

if ($Poll) { $PortalWaitSec = 40; $MaxRetry = 4; $RetryInterval = 5 }

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $PSScriptRoot 'login.log'
$Base    = "http://$PortalHost/eportal"

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    # Write-Host (not Write-Output) so log text never leaks into a function's return value
    Write-Host $line
    # keep the log file small
    try {
        $f = Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt 200KB) {
            $tail = Get-Content -LiteralPath $LogFile -Tail 300
            Set-Content -LiteralPath $LogFile -Value $tail -Encoding UTF8
        }
    } catch { }
}

function Invoke-PortalHttp {
    param([string]$Url, [int]$TimeoutSec = 6)

    $req = [System.Net.HttpWebRequest]::CreateHttp($Url)
    $req.Method            = 'GET'
    $req.AllowAutoRedirect = $false
    $req.Timeout           = $TimeoutSec * 1000
    $req.ReadWriteTimeout  = $TimeoutSec * 1000
    $req.UserAgent         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) CampusAutoLogin'
    $req.Headers['Cache-Control'] = 'no-cache'

    try {
        $resp = [System.Net.HttpWebResponse]$req.GetResponse()
        $body = ''
        try {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd(); $sr.Close()
        } catch { }
        $out = [pscustomobject]@{ Status = [int]$resp.StatusCode; Location = $resp.Headers['Location']; Body = $body }
        $resp.Close()
        return $out
    } catch [System.Net.WebException] {
        $w = $_.Exception.Response
        if ($null -ne $w) {
            $body = ''
            try {
                $sr = New-Object System.IO.StreamReader($w.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd(); $sr.Close()
            } catch { }
            $out = [pscustomobject]@{ Status = [int]$w.StatusCode; Location = $w.Headers['Location']; Body = $body }
            $w.Close()
            return $out
        }
        return [pscustomobject]@{ Status = 0; Location = $null; Body = $null }
    }
}

function Get-WlanSsid {
    try {
        $out = netsh wlan show interfaces 2>$null
        $m = $out | Select-String -Pattern '^\s*SSID\s*:\s*(.+)$'
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    } catch { }
    return $null
}

function Join-CampusWifi {
    param([string]$Ssid)

    if ($Ssid -eq '' -or $NoWifi) { return $false }

    $profiles = netsh wlan show profiles 2>$null
    if (-not ($profiles | Select-String -Pattern "^\s*.*:\s*$([regex]::Escape($Ssid))\s*$")) {
        Write-Log "no saved wifi profile named '$Ssid'"
        return $false
    }

    $cur = Get-WlanSsid
    if ($cur -eq $Ssid) { return $true }

    Write-Log "wifi is '$cur', switching to '$Ssid'"
    netsh wlan connect name="$Ssid" | Out-Null
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Seconds 3
        if ((Get-WlanSsid) -eq $Ssid) {
            Write-Log "associated with '$Ssid'"
            Start-Sleep -Seconds 4   # wait for DHCP
            return $true
        }
    }
    Write-Log "failed to associate with '$Ssid'"
    return $false
}

# true when this machine already has working internet through some other network
function Test-Internet {
    $r = Invoke-PortalHttp 'http://www.msftconnecttest.com/redirect' -TimeoutSec 5
    if ($r.Status -eq 200 -and $r.Body -match 'Microsoft Connect Test') { return $true }
    return $false
}

function Test-Portal {
    $r = Invoke-PortalHttp "$Base/" -TimeoutSec 4
    return ($r.Status -gt 0)
}

function Test-Online {
    $r = Invoke-PortalHttp "$Base/InterFace.do?method=getOnlineUserInfo"
    if ($r.Status -eq 200 -and $r.Body) {
        try {
            $j = $r.Body | ConvertFrom-Json
            if ($j.userId -eq $Account) { return $true }
        } catch { }
    }
    return $false
}

function Get-LocalIp {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($PortalHost, 80)
        $ep = $tcp.Client.LocalEndPoint.ToString()
        $tcp.Close()
        return $ep.Substring(0, $ep.LastIndexOf(':'))
    } catch { return $null }
}

function Get-LocalMac {
    param([string]$Ip)
    try {
        $addr = Get-NetIPAddress -IPAddress $Ip -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($addr) {
            $ad = Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex -ErrorAction SilentlyContinue
            if ($ad -and $ad.MacAddress) { return ($ad.MacAddress.ToLower() -replace ':', '-') }
        }
    } catch { }
    return $null
}

# Ask for a redirect from the captive portal; its Location carries the real queryString.
function Get-QueryString {
    $probes = @(
        'http://www.msftconnecttest.com/redirect',
        'http://www.example.com/',
        'http://neverssl.com/'
    )
    foreach ($u in $probes) {
        $r = Invoke-PortalHttp $u
        if ($r.Location -and $r.Location -match 'eportal/[a-zA-Z]+\.jsp\?(.+)$') {
            Write-Log "queryString captured from redirect: $u"
            return $Matches[1]
        }
    }

    # Fallback: build one from local interface info (used when HTTP probing is blocked).
    $ip  = Get-LocalIp
    $mac = if ($ip) { Get-LocalMac $ip } else { $null }
    if ($ip -and $mac) {
        $qs = "wlanuserip=$ip&wlanacname=$WlanAcName&nasip=$NasIp&wlanparameter=$mac&url=http://www.msftconnecttest.com/redirect"
        Write-Log "queryString built locally: $qs"
        return $qs
    }
    return $null
}

Write-Log "===== auto login start ($(if ($Poll) { 'poll' } else { 'boot' })) ====="

# 1) make sure we are attached to a network where the portal exists
if (-not (Test-Portal)) {
    $ssid = Get-WlanSsid
    Write-Log "portal $PortalHost unreachable (wifi='$ssid')"

    if ($ssid -ne $WlanSsid) {
        # on some other network: leave it alone if it already works
        if (Test-Internet) { Write-Log 'another network already provides internet, skip'; exit 0 }
        if (-not (Join-CampusWifi $WlanSsid)) { Write-Log 'cannot join campus network, abort'; exit 3 }
    }

    # wait for link + DHCP (long after boot, short on periodic checks)
    $deadline = (Get-Date).AddSeconds($PortalWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Portal) { break }
        Start-Sleep -Seconds 4
    }
    if (-not (Test-Portal)) { Write-Log "portal still unreachable after ${PortalWaitSec}s, abort"; exit 1 }
}

# 2) login loop
for ($i = 1; $i -le $MaxRetry; $i++) {
    if (-not $Force -and (Test-Online)) {
        Write-Log "already online as $Account"
        exit 0
    }

    $qs = Get-QueryString
    if (-not $qs) {
        Write-Log "try $i/$MaxRetry : no queryString (probably offline yet), retry in ${RetryInterval}s"
        Start-Sleep -Seconds $RetryInterval
        continue
    }

    if ($qs -is [array]) { $qs = $qs[-1] }

    $url = "$Base/InterFace.do?method=login" +
           '&userId='         + [uri]::EscapeDataString($Account) +
           '&password='       + [uri]::EscapeDataString($Password) +
           '&service='        + [uri]::EscapeDataString($Service) +
           '&queryString='    + [uri]::EscapeDataString($qs) +
           '&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false'

    $r = Invoke-PortalHttp $url -TimeoutSec 10
    if ($r.Status -eq 200 -and $r.Body) {
        try {
            $j = $r.Body | ConvertFrom-Json
        } catch { $j = $null }

        if ($j -and $j.result -eq 'success') {
            Start-Sleep -Seconds 2
            if (Test-Online) {
                Write-Log "login OK for $Account"
                exit 0
            }
            Write-Log 'login returned success but online check failed, retrying'
        } else {
            $msg = if ($j) { $j.message } else { $r.Body }
            Write-Log "try $i/$MaxRetry : login failed -> $msg"
            if ($msg -match '密码|用户名|账号|余额|停机|欠费|锁定') {
                Write-Log 'credential/billing problem, stop retrying'
                exit 2
            }
        }
    } else {
        Write-Log "try $i/$MaxRetry : login request failed (status=$($r.Status))"
    }

    Start-Sleep -Seconds $RetryInterval
}

Write-Log "login failed after $MaxRetry attempts"
exit 1
