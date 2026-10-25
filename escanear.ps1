<#
.SYNOPSIS
    Genera el inventario de archivos que necesita la app Space Cleaner.

.DESCRIPTION
    Escanea los discos indicados y crea en el Escritorio los CSV que
    server.ps1 después sirve a la interfaz:

      inventario_archivos.csv      -> todos los archivos (ordenado por antigüedad)
      inventario_tops.csv          -> los 100 archivos más pesados
      inventario_viejos_grandes.csv-> >100 MB sin usarse hace mucho
      inventario_carpetas.csv      -> peso por carpeta de nivel superior
      inventario_resumen.csv       -> totales

    IMPORTANTE: estos CSV contienen rutas y tamaños de TU equipo.
    Nunca se suben a ningún repositorio (.gitignore los excluye).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\escanear.ps1

.EXAMPLE
    # Escanear solo la unidad de usuario, más rápido
    powershell -ExecutionPolicy Bypass -File .\escanear.ps1 -Drives C:\
#>
param(
    [string[]]$Drives = @('C:\', 'D:\'),
    [string]$OutDir = ([Environment]::GetFolderPath('Desktop'))
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Write-Host "Escaneando: $($Drives -join ', ')" -ForegroundColor Cyan
Write-Host "Destino   : $OutDir" -ForegroundColor Cyan

$files = foreach ($d in $Drives) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue |
        Select-Object @{n = 'Ruta'; e = { $_.FullName }},
                      @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 2) } },
                      @{n = 'TamanoBytes'; e = { $_.Length } },
                      @{n = 'UltimaModificacion'; e = { $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } },
                      @{n = 'DiasSinUsar'; e = { [int]((Get-Date) - $_.LastWriteTime).TotalDays } },
                      @{n = 'Disco'; e = { $_.FullName.Substring(0, 2) } }
}

$orden = $files | Sort-Object DiasSinUsar -Descending
$orden | Export-Csv -Path (Join-Path $OutDir 'inventario_archivos.csv') -NoTypeInformation -Encoding UTF8

$masGrandes = $files | Sort-Object TamanoBytes -Descending | Select-Object -First 100
$viejosGrandes = $orden | Where-Object { $_.TamanoBytes -gt 100MB } | Select-Object -First 100

$carpetas = foreach ($d in $Drives) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $n = Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Carpeta  = $_.FullName
            Archivos = @($n).Count
            GB       = [math]::Round((($n | Measure-Object Length -Sum).Sum) / 1GB, 2)
        }
    }
}

[PSCustomObject]@{
    TotalArchivos = @($files).Count
    TotalGB       = [math]::Round((($files | Measure-Object TamanoBytes -Sum).Sum) / 1GB, 2)
    FechaEscaneo  = Get-Date -Format 'yyyy-MM-dd HH:mm'
} | Export-Csv -Path (Join-Path $OutDir 'inventario_resumen.csv') -NoTypeInformation -Encoding UTF8

$masGrandes | Export-Csv -Path (Join-Path $OutDir 'inventario_tops.csv') -NoTypeInformation -Encoding UTF8
$viejosGrandes | Export-Csv -Path (Join-Path $OutDir 'inventario_viejos_grandes.csv') -NoTypeInformation -Encoding UTF8
$carpetas | Sort-Object GB -Descending | Export-Csv -Path (Join-Path $OutDir 'inventario_carpetas.csv') -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "LISTO: $(@($files).Count) archivos inventariados." -ForegroundColor Green
Write-Host "Ya puedes lanzar iniciar.bat" -ForegroundColor Green
