#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string] $SessionDirectory)

$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $SessionDirectory 'connection.json') -Raw | ConvertFrom-Json
$tokenFile = Join-Path $SessionDirectory 'token'
$transportFile = Join-Path $SessionDirectory 'transport.json'
$phaseFile = Join-Path $SessionDirectory 'phase.json'
$stopFile = Join-Path $SessionDirectory 'stop'
$exe = Join-Path $PSScriptRoot 'sfera-net.exe'
$routes = [System.Collections.Generic.List[object]]::new()
$client = $null
$dnsConfigured = $false
$parent = $null
$mutex = [Threading.Mutex]::new($false, 'Global\SFERA.Windows.Tunnel')
$ownsMutex = $false
$stage = 'routes-error'
$failed = $false

function Write-Phase([string] $State) {
    @{state = $State} | ConvertTo-Json -Compress | Set-Content -LiteralPath $phaseFile -Encoding UTF8
}

function Should-Stop {
    return $parent.HasExited -or (Test-Path -LiteralPath $stopFile)
}

function Find-IPv4Route([string] $Address) {
    $route = Find-NetRoute -RemoteIPAddress $Address |
        Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } |
        Select-Object -First 1
    if (-not $route) { throw "No IPv4 route to $Address." }
    return $route
}

function Add-Route([string] $Prefix, [int] $InterfaceIndex, [string] $NextHop) {
    $route = New-NetRoute -DestinationPrefix $Prefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop `
        -RouteMetric 1 -PolicyStore ActiveStore
    $routes.Add($route)
}

try {
    $parent = Get-Process -Id $config.parent
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) {
        $stage = 'already-running'
        throw 'Another SFERA session is running.'
    }
    $prefixes4 = @('0.0.0.0/1', '128.0.0.0/1')
    $prefixes6 = @('::/1', '8000::/1')
    foreach ($prefix in ($prefixes4 + $prefixes6)) {
        if (Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue) {
            $stage = 'route-conflict'
            throw "A route for $prefix already exists."
        }
    }
    if (Get-NetIPAddress -IPAddress $config.peerIP -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
        $stage = 'route-conflict'
        throw 'An adapter already owns the profile address.'
    }
    # Resolve the original paths before any VPN routes are added.
    $underlay = @{}
    foreach ($address in (@($config.host) + @($config.direct) | Select-Object -Unique)) {
        $underlay[$address] = Find-IPv4Route $address
    }

    if (Should-Stop) { return }
    $stage = 'transport-error'
    Write-Phase 'connecting'
    $arguments = @('client', '--signal-url', "https://$($config.host)/api/session",
        '--signal-token-file', $tokenFile, '--tun-ip', $config.peerIP, '--peer-ip', $config.gateway,
        '--status-file', $transportFile)
    # PowerShell 5.1 joins ArgumentList into one native command line.
    $quoted = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $client = Start-Process -FilePath $exe -ArgumentList $quoted -NoNewWindow -PassThru
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $adapter = $null
    while (-not $client.HasExited -and $clock.Elapsed.TotalSeconds -lt 35) {
        if (Should-Stop) { return }
        try { $status = Get-Content -LiteralPath $transportFile -Raw | ConvertFrom-Json }
        catch { Start-Sleep -Milliseconds 200; continue }
        if ($status.state -eq 'connected' -and $status.pid -eq $client.Id) {
            $adapter = Get-NetIPAddress -InterfaceAlias $status.interface -IPAddress $config.peerIP `
                -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue
            if ($adapter) { break }
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not $adapter -or $client.HasExited) { throw 'The tunnel adapter did not become ready.' }
    Remove-Item -LiteralPath $tokenFile -Force
    if (Should-Stop) { return }

    $stage = 'routes-error'
    foreach ($address in $underlay.Keys) {
        $path = $underlay[$address]
        if ($path.InterfaceIndex -eq $adapter.InterfaceIndex) { throw 'An underlay path points into SFERA.' }
        if ($path.DestinationPrefix -ne "$address/32") {
            Add-Route "$address/32" $path.InterfaceIndex $path.NextHop
        }
    }
    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses @('1.1.1.1', '9.9.9.9')
    $dnsConfigured = $true
    # This transport carries IPv4. Send global IPv6 to Wintun, where it is dropped.
    foreach ($prefix in $prefixes6) { Add-Route $prefix $adapter.InterfaceIndex '::' }
    foreach ($prefix in $prefixes4) { Add-Route $prefix $adapter.InterfaceIndex $config.gateway }
    foreach ($address in $underlay.Keys) {
        if ((Find-IPv4Route $address).InterfaceIndex -ne $underlay[$address].InterfaceIndex) {
            throw 'An underlay route changed during connection.'
        }
    }
    foreach ($dns in @('1.1.1.1', '9.9.9.9')) {
        if ((Find-IPv4Route $dns).InterfaceIndex -ne $adapter.InterfaceIndex) {
            $stage = 'route-conflict'
            throw 'Another IPv4 route takes priority over the tunnel.'
        }
    }

    Write-Phase 'connected'
    $stage = 'transport-error'
    while (-not $client.HasExited -and -not (Should-Stop)) { Start-Sleep -Milliseconds 250 }
    if (-not (Should-Stop)) { throw 'SFERA transport exited.' }
} catch {
    $failed = $true
    Write-Phase $stage
} finally {
    if ($dnsConfigured) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    }
    for ($i = $routes.Count - 1; $i -ge 0; $i--) {
        Remove-NetRoute -InputObject $routes[$i] -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($client -and -not $client.HasExited) {
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
        $null = $client.WaitForExit(3000)
    }
    Remove-Item -LiteralPath $tokenFile -Force -ErrorAction SilentlyContinue
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    if ($parent -and $parent.HasExited) {
        Remove-Item -LiteralPath $SessionDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($failed) { exit 1 }
