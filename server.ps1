param (
    [int]$Port = 39841
)

$ErrorActionPreference = 'Stop'
$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================================
#  CONFIGURACIÓN
# ----------------------------------------------------------------------------
#  ProjectMarkers: nombres de carpetas de proyectos que estés usando ahora.
#  Se marcan siempre como "Conservar" y aparece una advertencia antes de
#  ejecutar cualquier acción sobre ellos.
#
#  Ejemplo:
#      $ProjectMarkers = @('mi-tienda', 'api-rest')
#
#  Déjalo vacío @() si no quieres ninguna protección especial.
# ============================================================================
$ProjectMarkers = @()

# Ensure Port is available, if not find next
while ($true) {
    try {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Start()
        break
    } catch {
        $Port++
        if ($Port -gt 39900) { throw "No se pudo vincular ningun puerto HTTP" }
    }
}

# Sin BOM: el lanzador .bat lee este archivo con "set /p"
[System.IO.File]::WriteAllText((Join-Path $AppDir "port.txt"), "$Port", (New-Object System.Text.UTF8Encoding $false))

function Get-DisksInfo {
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='D:'"
    return @{
        c = @{
            sizeBytes = [int64]$c.Size
            freeBytes = [int64]$c.FreeSpace
            usedBytes = [int64]($c.Size - $c.FreeSpace)
            sizeGB = [math]::Round($c.Size / 1GB, 1)
            freeGB = [math]::Round($c.FreeSpace / 1GB, 1)
            usedGB = [math]::Round(($c.Size - $c.FreeSpace) / 1GB, 1)
            percentUsed = [math]::Round((($c.Size - $c.FreeSpace) / $c.Size) * 100, 1)
        }
        d = @{
            available = ($null -ne $d)
            sizeBytes = if ($d) { [int64]$d.Size } else { 0 }
            freeBytes = if ($d) { [int64]$d.FreeSpace } else { 0 }
            usedBytes = if ($d) { [int64]($d.Size - $d.FreeSpace) } else { 0 }
            sizeGB = if ($d) { [math]::Round($d.Size / 1GB, 1) } else { 0 }
            freeGB = if ($d) { [math]::Round($d.FreeSpace / 1GB, 1) } else { 0 }
            usedGB = if ($d) { [math]::Round(($d.Size - $d.FreeSpace) / 1GB, 1) } else { 0 }
            percentUsed = if ($d -and $d.Size -gt 0) { [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 1) } else { 0 }
        }
    }
}

function Get-FilesData {
    # Rutas dinámicas: funciona en cualquier usuario/PC
    $Desktop = [Environment]::GetFolderPath('Desktop')
    $csvViejos = Join-Path $Desktop "inventario_viejos_grandes.csv"
    $csvTops   = Join-Path $Desktop "inventario_tops.csv"

    $list = @()
    if (Test-Path $csvViejos) { $list += Import-Csv $csvViejos -ErrorAction SilentlyContinue }
    if (Test-Path $csvTops)   { $list += Import-Csv $csvTops -ErrorAction SilentlyContinue }

    # Group by unique path
    $dict = @{}
    foreach ($row in $list) {
        $p = $row.Ruta
        if (-not $p -or $dict.ContainsKey($p)) { continue }

        $bytes = [int64]0
        if ($row.TamanoBytes) { [int64]::TryParse($row.TamanoBytes, [ref]$bytes) | Out-Null }
        if ($bytes -eq 0 -and $row.MB) {
            $mb = [double]0
            [double]::TryParse($row.MB.Replace(',', '.'), [ref]$mb) | Out-Null
            $bytes = [int64]($mb * 1MB)
        }

        $days = [int]0
        if ($row.DiasSinUsar) { [int]::TryParse($row.DiasSinUsar, [ref]$days) | Out-Null }

        $exists = Test-Path -LiteralPath $p

        # Intelligent classification
        $isSystem = ($p -match '(?i)^C:\\(pagefile|hiberfil|swapfile)\.sys|^C:\\Windows\\|^C:\\\$Recycle\.Bin|^C:\\System Volume Information')
        $isCurrentProject = $false
        if ($ProjectMarkers.Count -gt 0) {
            foreach ($m in $ProjectMarkers) {
                if ($m -and $p -like ("*\" + $m + "*")) { $isCurrentProject = $true; break }
            }
        }
        $isGame = ($p -match '(?i)\\(juegos|games|my games)\\|\\steam\\|\\gog games\\|\\epic games\\|\\battle\.net\\|\\riot games\\|\\minecraft\\')
        $isCache = ($p -match '(?i)\\(cache|caches|temp|tmp|dxcache|shaders)\\|OptGuideOnDevice|\\AppData\\Local\\Temp')

        $category = if ($isSystem) { 'system' }
                    elseif ($isCurrentProject) { 'current_project' }
                    elseif ($isGame) { 'game' }
                    elseif ($isCache) { 'cache' }
                    else { 'other' }

        $suggestedAction = if ($isSystem) { 'protected' }
                           elseif ($isCurrentProject) { 'keep' }
                           elseif ($isCache) { 'delete' }
                           elseif ($isGame) { 'move' }
                           elseif ($days -gt 730 -and $bytes -gt 500MB) { 'move' }
                           else { 'keep' }

        $name = Split-Path -Leaf $p
        $ext = [System.IO.Path]::GetExtension($p).TrimStart('.').ToLower()

        $destD = "D:\" + $p.Substring(3)

        $dict[$p] = @{
            path = $p
            name = $name
            ext = $ext
            bytes = $bytes
            mb = [math]::Round($bytes / 1MB, 1)
            gb = [math]::Round($bytes / 1GB, 2)
            days = $days
            date = $row.UltimaModificacion
            exists = $exists
            category = $category
            isSystem = $isSystem
            isCurrentProject = $isCurrentProject
            suggestedAction = $suggestedAction
            destinationD = $destD
        }
    }

    $result = @($dict.Values | Sort-Object bytes -Descending)
    return $result
}

Write-Host "Servidor escuchando en http://localhost:$Port/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        # CORS and common headers
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

        if ($request.HttpMethod -eq 'OPTIONS') {
            $response.StatusCode = 200
            $response.Close()
            continue
        }

        $urlPath = $request.Url.AbsolutePath

        try {
            if ($urlPath -eq '/' -or $urlPath -eq '/index.html') {
                $htmlPath = Join-Path $AppDir "app.html"
                if (Test-Path $htmlPath) {
                    $bytes = [System.IO.File]::ReadAllBytes($htmlPath)
                    $response.ContentType = "text/html; charset=utf-8"
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $response.StatusCode = 404
                }
            }
            elseif ($urlPath -eq '/api/disks') {
                $info = Get-DisksInfo
                $json = $info | ConvertTo-Json -Depth 4
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($urlPath -eq '/api/files') {
                $files = Get-FilesData
                $json = @{ files = $files } | ConvertTo-Json -Depth 4
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($urlPath -eq '/api/reveal') {
                $path = $request.QueryString['path']
                if ($path -and (Test-Path -LiteralPath $path)) {
                    Start-Process "explorer.exe" -ArgumentList "/select,`"$path`""
                    $json = @{ success = $true } | ConvertTo-Json
                } else {
                    $json = @{ success = $false; error = "Ruta no encontrada" } | ConvertTo-Json
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($urlPath -eq '/api/execute' -and $request.HttpMethod -eq 'POST') {
                $reader = [System.IO.StreamReader]::new($request.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reqData = $body | ConvertFrom-Json

                $results = @()
                $totalFreed = [int64]0

                foreach ($item in $reqData.actions) {
                    $p = $item.path
                    $act = $item.action # 'delete' or 'move'

                    # Safeguards
                    if ($p -match '(?i)^C:\\(pagefile|hiberfil|swapfile)\.sys|^C:\\Windows\\') {
                        $results += @{ path = $p; success = $false; error = "Archivo protegido de sistema" }
                        continue
                    }

                    if (-not (Test-Path -LiteralPath $p)) {
                        $results += @{ path = $p; success = $false; error = "El archivo ya no existe" }
                        continue
                    }

                    $fileSize = (Get-Item -LiteralPath $p).Length

                    if ($act -eq 'delete') {
                        try {
                            Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                            $totalFreed += $fileSize
                            $results += @{ path = $p; action = 'delete'; success = $true; freed = $fileSize }
                        } catch {
                            $results += @{ path = $p; action = 'delete'; success = $false; error = $_.Exception.Message }
                        }
                    }
                    elseif ($act -eq 'move') {
                        try {
                            $dest = "D:\" + $p.Substring(3)
                            $destDir = Split-Path -Parent $dest
                            if (-not (Test-Path -LiteralPath $destDir)) {
                                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                            }
                            Move-Item -LiteralPath $p -Destination $dest -Force -ErrorAction Stop
                            $totalFreed += $fileSize
                            $results += @{ path = $p; action = 'move'; destination = $dest; success = $true; freed = $fileSize }
                        } catch {
                            $results += @{ path = $p; action = 'move'; success = $false; error = $_.Exception.Message }
                        }
                    }
                }

                $respObj = @{
                    totalFreedBytes = $totalFreed
                    totalFreedMB = [math]::Round($totalFreed / 1MB, 1)
                    totalFreedGB = [math]::Round($totalFreed / 1GB, 2)
                    results = $results
                }
                $json = $respObj | ConvertTo-Json -Depth 4
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.ContentType = "application/json; charset=utf-8"
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($urlPath -eq '/api/shutdown') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"bye":true}')
                $response.ContentType = "application/json; charset=utf-8"
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.Close()
                break
            }
            else {
                $response.StatusCode = 404
            }
        } catch {
            $err = @{ error = $_.Exception.Message } | ConvertTo-Json
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($err)
            $response.StatusCode = 500
            $response.ContentType = "application/json; charset=utf-8"
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $response.Close()
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
