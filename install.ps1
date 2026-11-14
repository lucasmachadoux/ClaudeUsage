# Instala (ou desinstala) o atalho do widget na área de trabalho.
# Use os arquivos Instalar.cmd e Desinstalar.cmd, ou:
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Uninstall]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$AppName  = 'Uso do Claude'                 # nome do atalho na área de trabalho
$Base     = 'ClaudeUsage'                 # nome dos arquivos .ps1/.vbs/.ico
$CfgDir   = Join-Path $env:APPDATA 'ClaudeUsageWidget'
$Desc     = 'Uso dos limites do Claude (5 horas e semanal)'

$dir      = $PSScriptRoot
$desktop  = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
$startup  = Join-Path ([Environment]::GetFolderPath('Startup')) "$Base.lnk"

function Stop-Widget {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$Base.ps1*" } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      Wait-Process -Id $_.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
}

if ($Uninstall) {
  Stop-Widget
  foreach ($f in $desktop, $startup) { if (Test-Path $f) { Remove-Item $f -Force } }
  if (Test-Path $CfgDir) { Remove-Item $CfgDir -Recurse -Force }
  Write-Host "$AppName removido: atalhos e configurações apagados."
  Write-Host 'Os arquivos desta pasta não foram tocados; pode apagá-la se quiser.'
  return
}

# Arquivos baixados da internet vêm "bloqueados" pelo Windows; libera os desta pasta.
Get-ChildItem $dir -File | Unblock-File

$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($desktop)
$lnk.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
$lnk.Arguments        = '"' + (Join-Path $dir "$Base.vbs") + '"'
$lnk.WorkingDirectory = $dir
$lnk.IconLocation     = (Join-Path $dir "$Base.ico") + ',0'
$lnk.Description      = $Desc
$lnk.Save()

# Se o atalho de inicialização já existia (instalação antiga), aponta para esta pasta.
if (Test-Path $startup) {
  $s = $ws.CreateShortcut($startup)
  $s.Arguments = $lnk.Arguments; $s.WorkingDirectory = $dir; $s.IconLocation = $lnk.IconLocation
  $s.Save()
}

Write-Host "Atalho '$AppName' criado na área de trabalho."
Write-Host 'Para abrir junto com o Windows: botão direito no widget > Iniciar com o Windows.'

Stop-Widget
Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList $lnk.Arguments
Start-Sleep -Seconds 4
