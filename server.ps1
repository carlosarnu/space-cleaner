param (
    [int]$Port = 39841
)

# ============================================================================
#  Space Cleaner - servidor local
#  - Indexa TODOS los archivos de los discos fijos
#  - Sirve la interfaz en http://localhost:PUERTO/
#  - Solo acepta conexiones loopback (nunca expuesto a la red)
# ============================================================================

$ErrorActionPreference = 'Stop'
$AppDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$IndexFile  = Join-Path $AppDir 'index.csv'
$ProgFile   = Join-Path $AppDir 'scan_progress.json'
$Scanner    = Join-Path $AppDir 'scanner.ps1'
$HtmlFile   = Join-Path $AppDir 'app.html'
$enc        = New-Object System.Text.UTF8Encoding $false

# Carpetas de proyectos activos que quieres proteger:  @('mi-proyecto')
$ProjectMarkers = @()

# --- Puerto (busca el siguiente libre) ------------------------------------
while ($true) {
    try {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$Port/")
        $listener.Start()
        break
    } catch {
        $Port++
        if ($Port -gt 39900) { throw 'No se pudo vincular ningun puerto HTTP' }
    }
}
[System.IO.File]::WriteAllText((Join-Path $AppDir 'port.txt'), "$Port", $enc)

# ============================================================================
#  INDICE EN MEMORIA
#  Arrays paralelos, uno por archivo. Mucho mas ligero que objetos de PS.
# ============================================================================
$script:Idx      = $null
$script:IdxMtime = $null
$script:CacheKey = ''
$script:CacheArr = $null
$script:ScanProc = $null
$IC              = [System.StringComparison]::OrdinalIgnoreCase

function Get-CatCounts { param($a) }

function Load-Index {
    if (-not (Test-Path -LiteralPath $IndexFile)) { $script:Idx = $null; return $false }

    $mtime = (Get-Item -LiteralPath $IndexFile).LastWriteTimeUtc
    if ($script:Idx -and $script:IdxMtime -eq $mtime) { return $true }   # ya cargado

    $lines = [System.IO.File]::ReadAllLines($IndexFile)
    $n = $lines.Count - 1
    if ($n -le 0) { $script:Idx = $null; return $false }

    $paths = New-Object string[] $n
    $bytes = New-Object long[]   $n
    $days  = New-Object int[]    $n
    $dates = New-Object string[] $n
    $cats  = New-Object byte[]   $n
    $recs  = New-Object byte[]   $n

    $catCount = New-Object int[] 7
    $recCount = New-Object int[] 3
    $totalBytes = [int64]0
    $markers = @()
    if ($ProjectMarkers.Count -gt 0) {
        $markers = @($ProjectMarkers | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    }

    for ($i = 0; $i -lt $n; $i++) {
        $l = $lines[$i + 1]
        $p = ''; $b = [int64]0; $dy = 0; $dt = ''

        if ($l.Length -gt 6) {
            try {
                $f1 = $l.IndexOf('","')
                $f2 = $l.IndexOf('","', $f1 + 3)
                $f3 = $l.IndexOf('","', $f2 + 3)
                $e3 = $l.LastIndexOf('"')
                $p  = $l.Substring(1, $f1 - 1)
                $b  = [int64]$l.Substring($f1 + 3, $f2 - $f1 - 3)
                $dy = [int]$l.Substring($f2 + 3, $f3 - $f2 - 3)
                $dt = $l.Substring($f3 + 3, $e3 - $f3 - 3)
                $p  = $p.Replace('""', '"')
            } catch { $p = ''; $b = 0; $dy = 0; $dt = '' }
        }

        # ---- clasificacion (sin asignaciones: todo IndexOf ordinal) ----
        $cat = 0
        if ($p.Length -gt 4 -and $p[2] -eq [char]'\') {
            if ($p.IndexOf('Windows\', 3, $IC) -eq 3 -or
                $p.IndexOf('$Recycle.Bin', 3, $IC) -eq 3 -or
                $p.IndexOf('System Volume Information', 3, $IC) -eq 3 -or
                $p.IndexOf('Recovery\', 3, $IC) -eq 3 -or
                $p.IndexOf('Documents and Settings', 3, $IC) -eq 3 -or
                $p.IndexOf('pagefile.sys', 3, $IC) -eq 3 -or
                $p.IndexOf('hiberfil.sys', 3, $IC) -eq 3 -or
                $p.IndexOf('swapfile.sys', 3, $IC) -eq 3) { $cat = 1 }
            elseif ($p.IndexOf('Program Files', 3, $IC) -eq 3 -or
                    $p.IndexOf('Archivos de programa', 3, $IC) -eq 3 -or
                    $p.IndexOf('ProgramData\', 3, $IC) -eq 3) { $cat = 2 }
        }

        if ($cat -eq 0) {
            if ($p.IndexOf('node_modules', $IC) -ge 0) { $cat = 6 }
            elseif ($p.IndexOf('\temp\', $IC) -ge 0 -or $p.IndexOf('\tmp\', $IC) -ge 0 -or
                    $p.IndexOf('\cache\', $IC) -ge 0 -or $p.IndexOf('\caches\', $IC) -ge 0 -or
                    $p.IndexOf('\dxcache\', $IC) -ge 0 -or $p.IndexOf('\shadercache\', $IC) -ge 0 -or
                    $p.IndexOf('OptGuideOnDevice', $IC) -ge 0) { $cat = 3 }
            elseif ($p.IndexOf('\juegos\', $IC) -ge 0 -or $p.IndexOf('\games\', $IC) -ge 0 -or
                    $p.IndexOf('\my games\', $IC) -ge 0 -or $p.IndexOf('\steam\', $IC) -ge 0 -or
                    $p.IndexOf('\gog games\', $IC) -ge 0 -or $p.IndexOf('\epic games\', $IC) -ge 0 -or
                    $p.IndexOf('\riot games\', $IC) -ge 0 -or $p.IndexOf('\battle.net\', $IC) -ge 0) { $cat = 4 }
            elseif ($markers.Count -gt 0) {
                $low = $p.ToLowerInvariant()
                for ($mi = 0; $mi -lt $markers.Count; $mi++) {
                    if ($low.IndexOf($markers[$mi]) -ge 0) { $cat = 5; break }
                }
            }
        }

        # ---- recomendacion ----
        if     ($cat -eq 1 -or $cat -eq 2 -or $cat -eq 5) { $rec = 2 }   # no
        elseif ($cat -eq 3 -or $cat -eq 6)                 { $rec = 1 }   # si
        elseif ($cat -eq 4) {
            if     ($dy -gt 90) { $rec = 1 }
            elseif ($dy -le 30) { $rec = 2 }
            else                { $rec = 0 }
        } else {
            if     ($dy -gt 365) { $rec = 1 }
            elseif ($dy -le 30)  { $rec = 2 }
            else                 { $rec = 0 }
        }

        $paths[$i] = $p
        $bytes[$i] = $b
        $days[$i]  = $dy
        $dates[$i] = $dt
        $cats[$i]  = $cat
        $recs[$i]  = $rec
        $catCount[$cat]++
        $recCount[$rec]++
        $totalBytes += $b
    }

    $script:Idx = @{
        paths = $paths; bytes = $bytes; days = $days; dates = $dates
        cats  = $cats;  recs  = $recs;  n = $n
        catCount = $catCount; recCount = $recCount; totalBytes = $totalBytes
    }
    $script:IdxMtime = $mtime
    $script:CacheKey = ''
    $script:CacheArr = $null
    return $true
}

# ============================================================================
#  PAGINACION: filtra, ordena y devuelve una pagina
# ============================================================================
function Get-FilesPage {
    param($q, $group, $sort, $offset, $limit)

    $I = $script:Idx
    if (-not $I) { return @{ ready = $false; total = 0; files = @() } }

    $paths = $I.paths; $bytes = $I.bytes; $days = $I.days
    $dates = $I.dates; $cats  = $I.cats;  $recs = $I.recs
    $n = $I.n

    $key = "$q|$group|$sort"
    if ($script:CacheKey -ne $key -or -not $script:CacheArr) {
        $wantRec = -1; $wantCat = -1; $wantSys = $false
        switch ($group) {
            'si'        { $wantRec = 1 }
            'no'        { $wantRec = 2 }
            'revisar'   { $wantRec = 0 }
            'game'      { $wantCat = 4 }
            'cache'     { $wantCat = 3 }
            'nodemods'  { $wantCat = 6 }
            'project'   { $wantCat = 5 }
            'system'    { $wantSys = $true }
        }

        $arr = New-Object int[] $n
        $c = 0
        if ($q.Length -gt 0) {
            for ($i = 0; $i -lt $n; $i++) {
                if ($wantRec -ge 0 -and $recs[$i] -ne $wantRec) { continue }
                if ($wantCat -ge 0 -and $cats[$i] -ne $wantCat) { continue }
                if ($wantSys -and $cats[$i] -ne 1 -and $cats[$i] -ne 2) { continue }
                if ($paths[$i].IndexOf($q, $IC) -lt 0) { continue }
                $arr[$c++] = $i
            }
        } else {
            for ($i = 0; $i -lt $n; $i++) {
                if ($wantRec -ge 0 -and $recs[$i] -ne $wantRec) { continue }
                if ($wantCat -ge 0 -and $cats[$i] -ne $wantCat) { continue }
                if ($wantSys -and $cats[$i] -ne 1 -and $cats[$i] -ne 2) { continue }
                $arr[$c++] = $i
            }
        }
        if ($c -ne $n) { [Array]::Resize([ref]$arr, $c) }
        $items = $arr
        $m = $c

        # ---- orden ----
        if ($m -gt 1) {
            $desc = $false
            switch ($sort) {
                'sizeAsc' { }
                'daysDesc' { $desc = $true }
                'nameAsc'  { }
                'dateDesc' { $desc = $true }
                default    { $desc = $true }   # sizeDesc / dateAsc -> mas antiguo primero
            }
            try {
                switch ($sort) {
                    'sizeDesc' { $k = New-Object long[] $m;   for ($j=0;$j -lt $m;$j++){ $k[$j] = $bytes[$items[$j]] }; [Array]::Sort($k, $items) }
                    'sizeAsc'  { $k = New-Object long[] $m;   for ($j=0;$j -lt $m;$j++){ $k[$j] = $bytes[$items[$j]] }; [Array]::Sort($k, $items) }
                    'daysDesc' { $k = New-Object int[] $m;    for ($j=0;$j -lt $m;$j++){ $k[$j] = $days[$items[$j]]  }; [Array]::Sort($k, $items) }
                    'nameAsc'  { $k = New-Object string[] $m; for ($j=0;$j -lt $m;$j++){ $k[$j] = $paths[$items[$j]] }; [Array]::Sort($k, $items) }
                    default    { $k = New-Object string[] $m; for ($j=0;$j -lt $m;$j++){ $k[$j] = $dates[$items[$j]] }; [Array]::Sort($k, $items) }
                }
                if ($desc) { [Array]::Reverse($items) }
            } catch { }
        }

        $script:CacheKey = $key
        $script:CacheArr = $items
    } else {
        $items = $script:CacheArr
        $m = $items.Length
    }

    $total = $m
    if ($offset -lt 0) { $offset = 0 }
    if ($offset -ge $m) { return @{ ready = $true; total = $total; offset = $offset; files = @() } }
    $end = $offset + $limit - 1
    if ($end -gt $m - 1) { $end = $m - 1 }

    $files = for ($j = $offset; $j -le $end; $j++) {
        $i = $items[$j]
        @{ p = $paths[$i]; b = $bytes[$i]; d = $days[$i]; t = $dates[$i]; c = $cats[$i]; r = $recs[$i] }
    }
    return @{ ready = $true; total = $total; offset = $offset; files = @($files) }
}

# ============================================================================
#  ESCANEO
# ============================================================================
function Get-ScanState {
    $st = @{ available = $false; running = $false; done = $false; files = 0; bytes = 0; current = ''; error = '' }
    if (Test-Path -LiteralPath $ProgFile) {
        try {
            $j = [System.IO.File]::ReadAllText($ProgFile) | ConvertFrom-Json
            $st.running = [bool]$j.running
            $st.done    = [bool]$j.done
            $st.files   = [int64]$j.files
            $st.bytes   = [int64]$j.bytes
            $st.current = "$($j.current)"
            $st.error   = "$($j.error)"
        } catch { }
    }
    $st.available = (Test-Path -LiteralPath $IndexFile)
    return $st
}

function Start-Scan {
    if ($script:ScanProc -and -not $script:ScanProc.HasExited) {
        return @{ started = $false; reason = 'ya_en_ejecucion' }
    }
    if (Test-Path -LiteralPath $ProgFile) { Remove-Item -LiteralPath $ProgFile -Force -ErrorAction SilentlyContinue }
    $script:ScanProc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Scanner)) `
        -WindowStyle Hidden -PassThru
    return @{ started = $true; pid = $script:ScanProc.Id }
}

function Get-DisksInfo {
    $out = @{}
    foreach ($letter in @('C', 'D', 'E')) {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter`:'" -ErrorAction SilentlyContinue
        if (-not $d) { continue }
        $size = [int64]$d.Size; $free = [int64]$d.FreeSpace
        $out[$letter.ToLower()] = @{
            available = $true; sizeBytes = $size; freeBytes = $free
            usedBytes = ($size - $free)
            sizeGB = [math]::Round($size / 1GB, 1)
            freeGB = [math]::Round($free / 1GB, 1)
            usedGB = [math]::Round(($size - $free) / 1GB, 1)
            percentUsed = if ($size -gt 0) { [math]::Round((($size - $free) / $size) * 100, 1) } else { 0 }
        }
    }
    return $out
}

function Send-Json($res, $obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    $b = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.ContentType = 'application/json; charset=utf-8'
    $res.ContentLength64 = $b.Length
    $res.OutputStream.Write($b, 0, $b.Length)
}

# --- carga inicial (no bloquea el arranque si tarda) -----------------------
$initialLoaded = $false

Write-Host "Space Cleaner escuchando en http://localhost:$Port/"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        $res.Headers.Add('Access-Control-Allow-Origin', '*')
        $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
        if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 200; $res.Close(); continue }

        $url = $req.Url.AbsolutePath

        try {
            switch ($url) {
                '/' {
                    $b = [System.IO.File]::ReadAllBytes($HtmlFile)
                    $res.ContentType = 'text/html; charset=utf-8'
                    $res.ContentLength64 = $b.Length
                    $res.OutputStream.Write($b, 0, $b.Length)
                }
                '/api/state' {
                    # Carga perezosa del indice
                    if (-not $script:Idx) { $null = Load-Index }
                    $st = Get-ScanState
                    $st.ready = [bool]$script:Idx
                    $st.count = if ($script:Idx) { $script:Idx.n } else { 0 }
                    if ($script:Idx) {
                        $I = $script:Idx
                        $st.totalBytes = $I.totalBytes
                        $st.rec = @{ si = $I.recCount[1]; no = $I.recCount[2]; revisar = $I.recCount[0] }
                        $st.cat = @{
                            other = $I.catCount[0]; system = $I.catCount[1]; program = $I.catCount[2]
                            cache = $I.catCount[3]; game = $I.catCount[4]; project = $I.catCount[5]
                            nodemods = $I.catCount[6]
                        }
                    }
                    Send-Json $res $st
                }
                '/api/scan' {
                    if ($req.HttpMethod -eq 'POST') {
                        $r = Start-Scan
                        Send-Json $res $r
                    } else {
                        $st = Get-ScanState
                        $st.ready = [bool]$script:Idx
                        if ($st.done -and $st.available) { $null = Load-Index; $st.ready = [bool]$script:Idx; $st.count = if ($script:Idx) { $script:Idx.n } else { 0 } }
                        Send-Json $res $st
                    }
                }
                '/api/files' {
                    if (-not $script:Idx) { $null = Load-Index }
                    $qs = $req.QueryString
                    $q     = "$($qs['q'])".Trim()
                    $group = "$($qs['group'])"
                    $sort  = "$($qs['sort'])"
                    if ($sort -eq '') { $sort = 'sizeDesc' }
                    $offset = 0; $limit = 200
                    [void][int]::TryParse("$($qs['offset'])", [ref]$offset)
                    [void][int]::TryParse("$($qs['limit'])", [ref]$limit)
                    if ($limit -lt 1)   { $limit = 200 }
                    if ($limit -gt 1000) { $limit = 1000 }
                    Send-Json $res (Get-FilesPage $q $group $sort $offset $limit)
                }
                '/api/disks' { Send-Json $res (Get-DisksInfo) }
                '/api/reveal' {
                    $p = $req.QueryString['path']
                    if ($p -and (Test-Path -LiteralPath $p)) {
                        Start-Process 'explorer.exe' -ArgumentList "/select,`"$p`"" -ErrorAction SilentlyContinue
                        Send-Json $res @{ success = $true }
                    } else { Send-Json $res @{ success = $false; error = 'Ruta no encontrada' } }
                }
                '/api/execute' {
                    if ($req.HttpMethod -ne 'POST') { Send-Json $res @{ error = 'metodo no permitido' }; break }
                    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd()
                    $data = $body | ConvertFrom-Json

                    $results = @(); $freed = [int64]0
                    foreach ($item in @($data.actions)) {
                        $p = "$($item.path)"; $act = "$($item.action)"

                        if ($p -notmatch '^[A-Za-z]:\\') {
                            $results += @{ path = $p; action = $act; success = $false; error = 'Ruta no valida' }; continue
                        }
                        if ($act -notmatch '^(delete|move)$') {
                            $results += @{ path = $p; action = $act; success = $false; error = 'Accion no valida' }; continue
                        }
                        # Proteccion de sistema: se re-evalua AQUI, no en el cliente
                        if ($p.Length -gt 4 -and $p[2] -eq '\' -and
                            ($p.IndexOf('Windows\', 3, $IC) -eq 3 -or
                             $p.IndexOf('Program Files', 3, $IC) -eq 3 -or
                             $p.IndexOf('Archivos de programa', 3, $IC) -eq 3 -or
                             $p.IndexOf('ProgramData\', 3, $IC) -eq 3 -or
                             $p.IndexOf('System Volume Information', 3, $IC) -eq 3 -or
                             $p.IndexOf('$Recycle.Bin', 3, $IC) -eq 3 -or
                             $p.IndexOf('Recovery\', 3, $IC) -eq 3 -or
                             $p.IndexOf('pagefile.sys', 3, $IC) -eq 3 -or
                             $p.IndexOf('hiberfil.sys', 3, $IC) -eq 3 -or
                             $p.IndexOf('swapfile.sys', 3, $IC) -eq 3)) {
                            $results += @{ path = $p; action = $act; success = $false; error = 'Archivo protegido de sistema' }
                            continue
                        }
                        if (-not (Test-Path -LiteralPath $p)) {
                            $results += @{ path = $p; action = $act; success = $false; error = 'Ya no existe' }; continue
                        }

                        $size = 0
                        try { $size = (Get-Item -LiteralPath $p -Force).Length } catch { }

                        if ($act -eq 'delete') {
                            try {
                                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                                $freed += $size
                                $results += @{ path = $p; action = $act; success = $true; freed = $size }
                            } catch { $results += @{ path = $p; action = $act; success = $false; error = $_.Exception.Message } }
                        } else {
                            try {
                                $dest = 'D:\' + $p.Substring(3)
                                $dd = Split-Path -Parent $dest
                                if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                                Move-Item -LiteralPath $p -Destination $dest -Force -ErrorAction Stop
                                $freed += $size
                                $results += @{ path = $p; action = $act; destination = $dest; success = $true; freed = $size }
                            } catch { $results += @{ path = $p; action = $act; success = $false; error = $_.Exception.Message } }
                        }
                    }
                    Send-Json $res @{
                        totalFreedBytes = $freed
                        totalFreedMB = [math]::Round($freed / 1MB, 1)
                        totalFreedGB = [math]::Round($freed / 1GB, 3)
                        results = @($results)
                    }
                }
                '/api/shutdown' {
                    Send-Json $res @{ bye = $true }
                    $res.Close()
                    break
                }
                default { $res.StatusCode = 404 }
            }
        } catch {
            $err = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
            $b = [System.Text.Encoding]::UTF8.GetBytes($err)
            $res.StatusCode = 500
            $res.ContentType = 'application/json; charset=utf-8'
            $res.OutputStream.Write($b, 0, $b.Length)
        } finally {
            $res.Close()
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
