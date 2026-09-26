# Builds and persistently installs the compiled, per-user window repair helper.
[CmdletBinding(SupportsShouldProcess=$true)]
param()
$ErrorActionPreference='Stop'
$installDirectory=Join-Path $env:LOCALAPPDATA 'SpotXMinimizeGuard'
$exe=Join-Path $installDirectory 'SpotifyWindowHelper.exe'
$signal=Join-Path $installDirectory 'helper.stop'
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName='SpotXSpotifyWindowHelper'
$runValue='"'+$exe+'"'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$sources=@((Join-Path $PSScriptRoot 'SpotifyWindowHelper.cs'),(Join-Path $PSScriptRoot 'SpotifyFrameGuard.Native.cs'))
if(-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'Use 64-bit PowerShell on x64 Windows.'}
if([int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber -lt 22000){throw 'Windows 11 is required.'}
foreach($file in @($compiler)+$sources){if(-not(Test-Path -LiteralPath $file)){throw ('Required source/compiler missing: '+$file)}}
$previousRun=$null
if(Test-Path -LiteralPath $runKey){$property=(Get-ItemProperty -LiteralPath $runKey).PSObject.Properties[$runName];if($property){$previousRun=$property.Value}}
if($previousRun -and $previousRun -cne $runValue){throw 'The existing startup entry belongs to another command.'}
if(-not $PSCmdlet.ShouldProcess($installDirectory,'Build and install persistent compiled Spotify window repairs')){return}
function Stop-OwnedHelper {
    if(-not(Test-Path -LiteralPath $installDirectory)){return}
    [IO.File]::WriteAllText($signal,'stop')
    $deadline=(Get-Date).AddSeconds(20)
    do{
        $running=@(Get-Process SpotifyWindowHelper -ErrorAction SilentlyContinue | Where-Object Path -eq $exe)
        if(-not $running.Count){return}
        Start-Sleep -Milliseconds 250
    }while((Get-Date) -lt $deadline)
    throw 'The existing helper did not stop; it was not forcibly terminated.'
}
function Start-OwnedHelper {
    $shell=New-Object -ComObject Shell.Application
    try{$shell.ShellExecute($exe,'',$installDirectory,'open',0)}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    Start-Sleep -Seconds 3
    if(-not @(Get-Process SpotifyWindowHelper -ErrorAction SilentlyContinue | Where-Object Path -eq $exe).Count){throw 'The compiled helper did not start.'}
}
$stage=Join-Path ([IO.Path]::GetTempPath()) ('SpotXWindowBuild-'+[Guid]::NewGuid().ToString('N'))
$backup=Join-Path $stage 'previous.exe'
$replaced=$false
try{
    New-Item -ItemType Directory -Path $stage | Out-Null
    $built=Join-Path $stage 'SpotifyWindowHelper.exe'
    & $compiler /nologo /target:winexe /platform:x64 /r:System.Web.Extensions.dll ('/out:'+$built) @sources
    if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $built)){throw 'Helper compilation failed; previous installation unchanged.'}
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    if(Test-Path -LiteralPath $exe){Copy-Item -LiteralPath $exe -Destination $backup}
    Stop-OwnedHelper
    Copy-Item -LiteralPath $built -Destination $exe -Force
    $replaced=$true
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-SpotifyWindowHelper.ps1') -Destination $installDirectory -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SpotifyFrameGuard.Native.cs') -Destination $installDirectory -Force
    if(-not(Test-Path -LiteralPath $runKey)){New-Item -Path $runKey -Force | Out-Null}
    New-ItemProperty -LiteralPath $runKey -Name $runName -Value $runValue -PropertyType String -Force | Out-Null
    Remove-Item -LiteralPath $signal
    Start-OwnedHelper
    # Migrate the legacy watcher only after the replacement starts successfully.
    [IO.File]::WriteAllText((Join-Path $installDirectory 'stop.txt'),'stop')
    $legacy=Join-Path ([Environment]::GetFolderPath('Startup')) 'Spotify Minimize Guard.lnk'
    if(Test-Path -LiteralPath $legacy){
        $shell=New-Object -ComObject WScript.Shell
        try{$link=$shell.CreateShortcut($legacy);if($link.Arguments.Contains((Join-Path $installDirectory 'Watch-Spotify.ps1'))){Remove-Item -LiteralPath $legacy}}
        finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
    }
    # Migrate only a task registered by the previous helper installer.
    try{
        $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$folder=$scheduler.GetFolder('\')
        $task=$folder.GetTask('SpotX Spotify Window Helper')
        $actions=$task.Definition.Actions
        if($task.Definition.RegistrationInfo.Description -ceq 'Managed by SpotX Spotify Window Helper installer (SpotXMinimizeGuard-v1).' -and
           $actions.Count -eq 1 -and $actions.Item(1).Type -eq 0 -and $actions.Item(1).Path -ieq $exe){
            $task.Enabled=$false;$folder.DeleteTask($task.Name,0)
        }
    }catch{Write-Verbose 'No legacy owned helper task to migrate.'}
    Write-Host 'Installed persistent compiled Spotify window repairs. No background PowerShell is required.'
}catch{
    $failure=$_
    if($replaced){
        try{
            Stop-OwnedHelper
            if(Test-Path -LiteralPath $backup){Copy-Item -LiteralPath $backup -Destination $exe -Force}else{Remove-Item -LiteralPath $exe -ErrorAction SilentlyContinue}
            if($previousRun){Set-ItemProperty -LiteralPath $runKey -Name $runName -Value $previousRun}else{Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue}
            if(Test-Path -LiteralPath $signal){Remove-Item -LiteralPath $signal}
            if(Test-Path -LiteralPath $backup){Start-OwnedHelper}
        }catch{Write-Warning ('Restore failed: '+$_)}
    }
    throw $failure
}finally{
    $absolute=[IO.Path]::GetFullPath($stage)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute).StartsWith('SpotXWindowBuild-') -and(Test-Path -LiteralPath $absolute)){
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
