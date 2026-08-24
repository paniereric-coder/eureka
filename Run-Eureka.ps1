$ErrorActionPreference = "Stop"

$log = "C:\work\PERSO\eureka\eureka-task.log"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class PowerManager
{
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

[uint32]$ES_CONTINUOUS      = 0x80000000L
[uint32]$ES_SYSTEM_REQUIRED = 0x00000001
[uint32]$keepAwakeFlags     = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED

Start-Transcript -Path $log -Append

$exitCode = 0

try {
    [PowerManager]::SetThreadExecutionState(
        $keepAwakeFlags
    ) | Out-Null

    Write-Host "Mise en veille suspendue pendant le telechargement."

    & "C:\work\PERSO\eureka\Eureka.ps1" `
        -Liste "C:\work\PERSO\eureka\liste.csv"

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
    [PowerManager]::SetThreadExecutionState(
        $ES_CONTINUOUS
    ) | Out-Null

    Write-Host "Mise en veille de nouveau autorisee."

    Stop-Transcript
}

exit $exitCode