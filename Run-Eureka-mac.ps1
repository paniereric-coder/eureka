$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$log = Join-Path $scriptDir "eureka-task.log"

Start-Transcript -Path $log -Append

$exitCode = 0
$caffeinate = $null

try {
    # Empeche la mise en veille pendant le telechargement (macOS).
    $caffeinate = Start-Process -FilePath "caffeinate" -ArgumentList "-dimsu" -PassThru -ErrorAction SilentlyContinue
    if ($caffeinate) {
        Write-Host "Mise en veille suspendue pendant le telechargement."
    }

    & (Join-Path $scriptDir "Eureka-mac.ps1") `
        -Liste (Join-Path $scriptDir "liste.csv")

    if ($null -ne $LASTEXITCODE) {
        $exitCode = $LASTEXITCODE
    }
}
catch {
    Write-Host ""
    Write-Host "ERREUR FATALE :"
    Write-Host $_

    $exitCode = 1
}
finally {
    if ($caffeinate -and -not $caffeinate.HasExited) {
        $caffeinate | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "Mise en veille de nouveau autorisee."
    }

    Stop-Transcript
}

exit $exitCode