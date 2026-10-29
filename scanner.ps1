<#
    Escanea TODOS los discos fijos y genera el indice completo de archivos.
    No escribe nada en el Escritorio: todo vive en la carpeta de la app.

    Formato de index.csv (una linea por archivo):
        "ruta","bytes","dias_sin_usar","fecha_ultima_modificacion"
#>
param([string]$AppDir = '')

$ErrorActionPreference = 'SilentlyContinue'

if (-not $AppDir) { $AppDir = $PSScriptRoot }
if (-not $AppDir) { $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$IndexFile = Join-Path $AppDir 'index.csv'
$TmpFile   = Join-Path $AppDir 'index.tmp'
$ProgFile  = Join-Path $AppDir 'scan_progress.json'
$enc       = New-Object System.Text.UTF8Encoding $false

function Write-ProgressFile {
    param($running, $files, $bytes, $current, $done, $err)
    $obj = [ordered]@{
        running = [bool]$running
        files   = [int64]$files
        bytes   = [int64]$bytes
        current = "$current"
        done    = [bool]$done
        error   = "$err"
        updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $json = $obj | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($ProgFile, $json, $enc)
}

# --- Estado inicial -------------------------------------------------------
Write-ProgressFile $true 0 0 'Iniciando' $false $null

$now     = Get-Date
$writer  = New-Object System.IO.StreamWriter($TmpFile, $false, $enc)
$writer.AutoFlush = $false
$writer.WriteLine('"Ruta","TamanoBytes","DiasSinUsar","UltimaModificacion"')

# Discos fijos (DriveType=3), con y sin letra de unidad accesible
$drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
            ForEach-Object { $_.DeviceID + '\' })
if ($drives.Count -eq 0) { $drives = @('C:\') }

$stack = New-Object 'System.Collections.Generic.Stack[string]'
foreach ($d in $drives) { $stack.Push($d) }

$count      = 0
$totalBytes = [int64]0
$lastReport = 0
$saltedDirs = 0

while ($stack.Count -gt 0) {
    $dir = $stack.Pop()

    $di = New-Object System.IO.DirectoryInfo $dir
    if (-not $di.Exists) { continue }

    # Subcarpetas primero (LIFO => se recorre en orden natural)
    try {
        foreach ($sub in $di.EnumerateDirectories()) {
            $stack.Push($sub.FullName)
        }
    } catch {
        $saltedDirs++
    }

    # Archivos de esta carpeta
    try {
        foreach ($fi in $di.EnumerateFiles()) {
            try {
                $len  = $fi.Length
                $lwt  = $fi.LastWriteTime
                $days = [int]($now - $lwt).TotalDays
                $p    = $fi.FullName.Replace('"', '""')
                $writer.WriteLine('"' + $p + '","' + $len + '","' + $days +
                                  '","' + $lwt.ToString('yyyy-MM-dd HH:mm') + '"')
                $count++
                $totalBytes += $len
            } catch { }
        }
    } catch {
        $saltedDirs++
    }

    # Progreso cada 2.000 archivos
    if (($count - $lastReport) -ge 2000) {
        $lastReport = $count
        $writer.Flush()
        Write-ProgressFile $true $count $totalBytes $dir $false $null
    }
}

$writer.Flush()
$writer.Close()

# Cambio atomico: el servidor solo lee index.csv completo
if (Test-Path -LiteralPath $IndexFile) { Remove-Item -LiteralPath $IndexFile -Force }
Move-Item -LiteralPath $TmpFile -Destination $IndexFile -Force

Write-ProgressFile $false $count $totalBytes '' $true $null
