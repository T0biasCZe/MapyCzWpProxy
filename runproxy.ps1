param(
    [int]$Port = 8080,
    [string]$Prefix = "http://*:$Port/",
    [string]$CacheDir = "$PSScriptRoot/cache",
    [int]$CacheTtlSeconds = 604800,
    [int]$ConnectTimeout = 10,
    [int]$TotalTimeout = 30
)

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    
    foreach ($key in $PSBoundParameters.Keys) {
        $argList += "-$key"
        $argList += "`"$($PSBoundParameters[$key])`""
    }

    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    exit
}

$AllowedHostSuffixes = @('mapy.cz', 'mapy.com')

function Test-HostAllowed ([string]$hostName) {
    $h = $hostName.TrimEnd('.').ToLowerInvariant()
    foreach ($allowed in $AllowedHostSuffixes) {
        if ($h -eq $allowed -or $h.EndsWith(".$allowed")) {
            return $true
        }
    }
    return $false
}

function Send-Fail ($response, [int]$status, [string]$message) {
    $response.StatusCode = $status
    $response.ContentType = "text/plain; charset=utf-8"
    $response.AddHeader("Cache-Control", "no-store")
    $buffer = [System.Text.Encoding]::UTF8.GetBytes("$message`n")
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Close()
}

$cacheEnabled = $CacheTtlSeconds -gt 0
if ($cacheEnabled -and -not (Test-Path -Path $CacheDir)) {
    try {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    } catch {
        $cacheEnabled = $false
    }
}

$sha1 = [System.Security.Cryptography.SHA1]::Create()
function Get-Sha1Hex ([string]$str) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($str)
    $hash = $sha1.ComputeHash($bytes)
    return (-join ($hash | ForEach-Object { $_.ToString("x2") }))
}

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
if ($handler.SupportsAutomaticDecompression) {
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
}

$httpClient = New-Object System.Net.Http.HttpClient($handler)
$httpClient.Timeout = [TimeSpan]::FromSeconds($TotalTimeout)
$httpClient.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (compatible; MapyCzWpClientRT-proxy/1.0)") | Out-Null
$httpClient.DefaultRequestHeaders.TryAddWithoutValidation("Referer", "https://mapy.com/") | Out-Null

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)

try {
    $listener.Start()

    $localIps = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { 
            $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and 
            -not [System.Net.IPAddress]::IsLoopback($_) 
        } |
        Select-Object -ExpandProperty IPAddressToString

    Write-Host "Mapy proxy listening on port $Port..." -ForegroundColor Green
    if ($localIps) {
        Write-Host "Use one of these endpoints on your Windows Phone:" -ForegroundColor Cyan
        foreach ($ip in $localIps) {
            Write-Host "  -> http://${ip}:$Port/" -ForegroundColor Yellow
        }
    }
    Write-Host "Press Ctrl+C to stop.`n"

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $url = $request.QueryString["url"]
        if ([string]::IsNullOrEmpty($url)) {
            Send-Fail $response 400 "Missing ?url= parameter."
            continue
        }

        if ($url.Length -gt 2048) {
            Send-Fail $response 414 "URL too long."
            continue
        }

        $uri = $null
        $isValidUri = [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)
        if (-not $isValidUri -or ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https')) {
            Send-Fail $response 400 "Malformed or unsupported URL scheme."
            continue
        }

        if (-not (Test-HostAllowed $uri.Host)) {
            Send-Fail $response 403 "Host not allowed: $($uri.Host)"
            continue
        }

        $key = Get-Sha1Hex $url
        $cacheFile = Join-Path $CacheDir "$key.bin"
        $metaFile  = Join-Path $CacheDir "$key.type"

        $isHit = $false
        if ($cacheEnabled -and (Test-Path $cacheFile)) {
            $age = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalSeconds
            if ($age -lt $CacheTtlSeconds) {
                $isHit = $true
            }
        }

        if ($isHit) {
            $contentType = "application/octet-stream"
            if (Test-Path $metaFile) {
                $contentType = (Get-Content $metaFile -Raw).Trim()
            }
            $bodyBytes = [System.IO.File]::ReadAllBytes($cacheFile)
            $response.StatusCode = 200
            $response.ContentType = $contentType
            $response.ContentLength64 = $bodyBytes.Length
            $response.AddHeader("Cache-Control", "public, max-age=$CacheTtlSeconds")
            $response.AddHeader("X-Proxy-Cache", "HIT")
            $response.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length)
            $response.OutputStream.Close()
            continue
        }

        try {
            $upstreamResponse = $httpClient.GetAsync($uri).GetAwaiter().GetResult()
        } catch {
            Send-Fail $response 502 "Upstream fetch failed: $($_.Exception.Message)"
            continue
        }

        $statusCode = [int]$upstreamResponse.StatusCode
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            Send-Fail $response $statusCode "Upstream returned HTTP $statusCode"
            continue
        }

        $contentType = $upstreamResponse.Content.Headers.ContentType.ToString()
        if ([string]::IsNullOrEmpty($contentType)) {
            $contentType = "application/octet-stream"
        }

        $bodyBytes = $upstreamResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()

        if ($cacheEnabled) {
            $tmpFile = "$cacheFile.$([System.Diagnostics.Process]::GetCurrentProcess().Id).tmp"
            try {
                [System.IO.File]::WriteAllBytes($tmpFile, $bodyBytes)
                if (Test-Path $cacheFile) { Remove-Item $cacheFile -Force }
                Move-Item -Path $tmpFile -Destination $cacheFile -Force
                [System.IO.File]::WriteAllText($metaFile, $contentType)
            } catch {
                if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
            }
        }

        $response.StatusCode = 200
        $response.ContentType = $contentType
        $response.ContentLength64 = $bodyBytes.Length
        $response.AddHeader("Cache-Control", "public, max-age=$CacheTtlSeconds")
        $response.AddHeader("X-Proxy-Cache", "MISS")
        $response.OutputStream.Write($bodyBytes, 0, $bodyBytes.Length)
        $response.OutputStream.Close()
    }
} finally {
    $listener.Stop()
    $listener.Close()
    $httpClient.Dispose()
}
