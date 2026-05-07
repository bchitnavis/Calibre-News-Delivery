[CmdletBinding()]
param(
    [ValidateSet('edge', 'chrome', 'firefox')]
    [string]$Browser = 'edge',
    [string]$Domain = 'nytimes.com',
    [string]$ConfigPath = '.\standalone.config.json',
    [switch]$UpdateConfig,
    [switch]$CopyToClipboard
)

$ErrorActionPreference = 'Stop'

function Ensure-ProtectedDataType {
    if ('System.Security.Cryptography.ProtectedData' -as [type]) {
        return
    }

    $assemblies = @(
        'System.Security',
        'System.Security.Cryptography.ProtectedData'
    )

    foreach ($asm in $assemblies) {
        try {
            Add-Type -AssemblyName $asm -ErrorAction Stop
            if ('System.Security.Cryptography.ProtectedData' -as [type]) {
                return
            }
        }
        catch {
            continue
        }
    }

    throw 'DPAPI type not available: System.Security.Cryptography.ProtectedData. Run this script in Windows PowerShell 5.1 on Windows or install the required .NET cryptography assembly.'
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found in PATH: $Name"
    }
}

function Get-PythonCommand {
    $candidates = @('py', 'python')
    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $candidate
        }
    }

    return $null
}

function Invoke-SqliteQuery {
    param(
        [string]$DatabasePath,
        [string]$Sql
    )

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($sqlite) {
        return & sqlite3 -separator "`t" $DatabasePath $Sql
    }

    $pythonCmd = Get-PythonCommand
    if (-not $pythonCmd) {
        throw 'Neither sqlite3.exe nor Python (py/python) is available in PATH.'
    }

    $tempScript = Join-Path $env:TEMP ("sqlite-query-{0}.py" -f [Guid]::NewGuid().ToString('N'))
    $pythonSource = @"
import sqlite3
import sys

db_path = sys.argv[1]
sql = sys.argv[2]

conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    for row in cur.execute(sql):
        print("\t".join("" if value is None else str(value) for value in row))
finally:
    conn.close()
"@

    Set-Content -LiteralPath $tempScript -Value $pythonSource -Encoding utf8
    try {
        return & $pythonCmd $tempScript $DatabasePath $Sql
    }
    finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Convert-HexToBytes {
    param([string]$Hex)

    if ([string]::IsNullOrWhiteSpace($Hex)) {
        return [byte[]]::new(0)
    }

    if ($Hex.Length % 2 -ne 0) {
        throw "Invalid hex string length: $($Hex.Length)"
    }

    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $Hex.Length; $i += 2) {
        $bytes[$i / 2] = [Convert]::ToByte($Hex.Substring($i, 2), 16)
    }
    return $bytes
}

function Unprotect-DpapiData {
    param([byte[]]$Bytes)

    Ensure-ProtectedDataType

    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Decrypt-ChromiumCookie {
    param(
        [string]$EncryptedHex,
        [byte[]]$MasterKey
    )

    $enc = Convert-HexToBytes -Hex $EncryptedHex
    if ($enc.Length -eq 0) {
        return ''
    }

    # New Chromium format: v10|v11 + 12 byte nonce + ciphertext + 16 byte tag
    if ($enc.Length -gt 3 -and $enc[0] -eq 0x76 -and $enc[1] -eq 0x31 -and ($enc[2] -eq 0x30 -or $enc[2] -eq 0x31)) {
        if ($MasterKey.Length -eq 0) {
            throw 'Missing Chromium master key for v10/v11 cookie decryption.'
        }

        $nonce = $enc[3..14]
        $cipherWithTag = $enc[15..($enc.Length - 1)]
        if ($cipherWithTag.Length -lt 17) {
            throw 'Invalid encrypted cookie payload.'
        }

        $cipherLen = $cipherWithTag.Length - 16
        $cipher = New-Object byte[] $cipherLen
        $tag = New-Object byte[] 16
        [Array]::Copy($cipherWithTag, 0, $cipher, 0, $cipherLen)
        [Array]::Copy($cipherWithTag, $cipherLen, $tag, 0, 16)

        $plain = New-Object byte[] $cipherLen
        $aes = [System.Security.Cryptography.AesGcm]::new($MasterKey)
        try {
            $aes.Decrypt($nonce, $cipher, $tag, $plain)
        }
        finally {
            $aes.Dispose()
        }
        return [Text.Encoding]::UTF8.GetString($plain)
    }

    # Legacy DPAPI encrypted cookie
    $plainLegacy = Unprotect-DpapiData -Bytes $enc
    return [Text.Encoding]::UTF8.GetString($plainLegacy)
}

function Get-ChromiumPaths {
    param([string]$BrowserName)

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    switch ($BrowserName.ToLowerInvariant()) {
        'edge' {
            $base = Join-Path $localAppData 'Microsoft\Edge\User Data'
        }
        'chrome' {
            $base = Join-Path $localAppData 'Google\Chrome\User Data'
        }
        default {
            throw "Unsupported browser: $BrowserName"
        }
    }

    return [pscustomobject]@{
        LocalState = Join-Path $base 'Local State'
        CookieDb   = Join-Path $base 'Default\Network\Cookies'
    }
}

function Get-FirefoxCookieDbPath {
    $roamingAppData = [Environment]::GetFolderPath('ApplicationData')
    $profilesRoot = Join-Path $roamingAppData 'Mozilla\Firefox\Profiles'

    if (Test-Path -LiteralPath $profilesRoot) {
        $profiles = Get-ChildItem -LiteralPath $profilesRoot -Directory
        if ($profiles) {
            $preferred = $profiles | Where-Object { $_.Name -like '*.default-release' } | Select-Object -First 1
            if (-not $preferred) {
                $preferred = $profiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            }

            $cookieDb = Join-Path $preferred.FullName 'cookies.sqlite'
            if (Test-Path -LiteralPath $cookieDb) {
                return $cookieDb
            }
        }
    }

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $packagesRoot = Join-Path $localAppData 'Packages'
    if (Test-Path -LiteralPath $packagesRoot) {
        $storePackage = Get-ChildItem -LiteralPath $packagesRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Mozilla.Firefox*' } |
            Select-Object -First 1

        if ($storePackage) {
            $storeCookie = Get-ChildItem -LiteralPath $storePackage.FullName -Recurse -Filter 'cookies.sqlite' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($storeCookie) {
                return $storeCookie.FullName
            }
        }
    }

    throw "Firefox cookies.sqlite not found in either classic profile path ($profilesRoot) or Microsoft Store package data."
}

function Get-ChromiumMasterKey {
    param([string]$LocalStatePath)

    if (-not (Test-Path -LiteralPath $LocalStatePath)) {
        throw "Chromium Local State not found: $LocalStatePath"
    }

    $json = Get-Content -LiteralPath $LocalStatePath -Raw | ConvertFrom-Json
    $encryptedKeyB64 = $json.os_crypt.encrypted_key
    if ([string]::IsNullOrWhiteSpace($encryptedKeyB64)) {
        throw 'Could not read encrypted_key from Local State.'
    }

    $keyWithPrefix = [Convert]::FromBase64String($encryptedKeyB64)
    if ($keyWithPrefix.Length -le 5) {
        throw 'Invalid encrypted key format.'
    }

    # Prefix is ASCII DPAPI
    $dpapiBlob = $keyWithPrefix[5..($keyWithPrefix.Length - 1)]
    return Unprotect-DpapiData -Bytes $dpapiBlob
}

function Get-CookiesFromDb {
    param(
        [string]$CookieDbPath,
        [string]$DomainFilter,
        [byte[]]$MasterKey
    )

    if (-not (Test-Path -LiteralPath $CookieDbPath)) {
        throw "Cookies DB not found: $CookieDbPath"
    }

    $tempDb = Join-Path $env:TEMP ("nyt-cookies-{0}.db" -f [Guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $CookieDbPath -Destination $tempDb -Force

    try {
        $safeDomain = $DomainFilter.Replace("'", "''")
        $sql = @"
SELECT name, value, hex(encrypted_value)
FROM cookies
WHERE host_key LIKE '%$safeDomain%'
ORDER BY name;
"@

        $rows = Invoke-SqliteQuery -DatabasePath $tempDb -Sql $sql
        if (-not $rows) {
            return @()
        }

        $result = @()
        foreach ($row in $rows) {
            $parts = $row -split "`t", 3
            if ($parts.Count -lt 3) {
                continue
            }

            $name = $parts[0]
            $value = $parts[1]
            $encryptedHex = $parts[2]

            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            if ([string]::IsNullOrEmpty($value)) {
                try {
                    $value = Decrypt-ChromiumCookie -EncryptedHex $encryptedHex -MasterKey $MasterKey
                }
                catch {
                    Write-Warning ("Failed to decrypt cookie {0}: {1}" -f $name, $_.Exception.Message)
                    continue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $result += [pscustomobject]@{ Name = $name; Value = $value }
            }
        }

        return $result
    }
    finally {
        Remove-Item -LiteralPath $tempDb -Force -ErrorAction SilentlyContinue
    }
}

function Get-FirefoxCookiesFromDb {
    param(
        [string]$CookieDbPath,
        [string]$DomainFilter
    )

    if (-not (Test-Path -LiteralPath $CookieDbPath)) {
        throw "Cookies DB not found: $CookieDbPath"
    }

    $tempDb = Join-Path $env:TEMP ("nyt-cookies-{0}.db" -f [Guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $CookieDbPath -Destination $tempDb -Force

    try {
        $safeDomain = $DomainFilter.Replace("'", "''")
        $sql = @"
SELECT name, value
FROM moz_cookies
WHERE host LIKE '%$safeDomain%'
ORDER BY name;
"@

        $rows = Invoke-SqliteQuery -DatabasePath $tempDb -Sql $sql
        if (-not $rows) {
            return @()
        }

        $result = @()
        foreach ($row in $rows) {
            $parts = $row -split "`t", 2
            if ($parts.Count -lt 2) {
                continue
            }

            $name = $parts[0]
            $value = $parts[1]
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $result += [pscustomobject]@{ Name = $name; Value = $value }
        }

        return $result
    }
    finally {
        Remove-Item -LiteralPath $tempDb -Force -ErrorAction SilentlyContinue
    }
}

try {
    if ($Browser -eq 'firefox') {
        $cookieDb = Get-FirefoxCookieDbPath
        $cookies = Get-FirefoxCookiesFromDb -CookieDbPath $cookieDb -DomainFilter $Domain
    }
    else {
        $paths = Get-ChromiumPaths -BrowserName $Browser
        $masterKey = Get-ChromiumMasterKey -LocalStatePath $paths.LocalState
        $cookies = Get-CookiesFromDb -CookieDbPath $paths.CookieDb -DomainFilter $Domain -MasterKey $masterKey
    }

    if ($cookies.Count -eq 0) {
        throw "No cookies found for domain: $Domain"
    }

    # Deduplicate by cookie name while preserving first seen order.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($cookie in $cookies) {
        if ($seen.Add($cookie.Name)) {
            $pairs.Add(("{0}={1}" -f $cookie.Name, $cookie.Value))
        }
    }

    $header = [string]::Join('; ', $pairs)

    if ($UpdateConfig) {
        $configFullPath = [System.IO.Path]::GetFullPath($ConfigPath)
        if (-not (Test-Path -LiteralPath $configFullPath)) {
            throw "Config file not found: $configFullPath"
        }

        $config = Get-Content -LiteralPath $configFullPath -Raw | ConvertFrom-Json
        if (-not $config.nytAuth) {
            $config | Add-Member -NotePropertyName nytAuth -NotePropertyValue ([pscustomobject]@{})
        }

        $config.nytAuth.cookieHeader = $header
        if (-not $config.nytAuth.PSObject.Properties.Name.Contains('username')) {
            $config.nytAuth | Add-Member -NotePropertyName username -NotePropertyValue ''
        }
        if (-not $config.nytAuth.PSObject.Properties.Name.Contains('password')) {
            $config.nytAuth | Add-Member -NotePropertyName password -NotePropertyValue ''
        }

        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configFullPath -Encoding utf8
        Write-Host ("Updated nytAuth.cookieHeader in: {0}" -f $configFullPath)
    }

    if ($CopyToClipboard) {
        Set-Clipboard -Value $header
        Write-Host 'Cookie header copied to clipboard.'
    }

    Write-Host ''
    Write-Host 'NYT Cookie Header:'
    Write-Host $header
    Write-Host ''
    Write-Host ("Cookie count: {0}" -f $pairs.Count)
}
catch {
    Write-Error $_
    exit 1
}
