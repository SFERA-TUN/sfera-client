#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Transport,
    [Parameter(Mandatory)][string] $Output
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$staging = Join-Path ([IO.Path]::GetTempPath()) ('sfera-windows-' + [Guid]::NewGuid().ToString('N'))
$app = Join-Path $staging 'SFERA'
try {
    New-Item -ItemType Directory -Path $staging | Out-Null
    dotnet publish (Join-Path $root 'windows\SFERA.Windows.csproj') -c Release -r win-x64 `
        --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $app
    if ($LASTEXITCODE -ne 0) { throw 'Windows client build failed.' }

    $wintun = Join-Path $staging 'wintun.zip'
    Invoke-WebRequest -UseBasicParsing 'https://www.wintun.net/builds/wintun-0.14.1.zip' -OutFile $wintun
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $wintun).Hash -ne '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51') {
        throw 'The Wintun archive checksum does not match.'
    }
    Expand-Archive -LiteralPath $wintun -DestinationPath $staging
    Copy-Item -LiteralPath (Join-Path $staging 'wintun\bin\amd64\wintun.dll') -Destination $app
    Copy-Item -LiteralPath (Join-Path $staging 'wintun\LICENSE.txt') -Destination (Join-Path $app 'LICENSE-Wintun.txt')
    Copy-Item -LiteralPath $Transport -Destination (Join-Path $app 'sfera-net.exe')
    Copy-Item -LiteralPath (Join-Path $root 'windows\README.md') -Destination $app

    foreach ($name in @('SFERA.exe', 'sfera-net.exe', 'wintun.dll', 'Connect-Sfera.ps1', 'LICENSE-Wintun.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $app $name) -PathType Leaf)) { throw "Missing $name." }
    }
    Compress-Archive -LiteralPath $app -DestinationPath $Output -Force
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
