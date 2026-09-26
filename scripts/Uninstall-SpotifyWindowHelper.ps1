# Disable persistent repairs, leaving Spotify and recovery data intact.
[CmdletBinding(SupportsShouldProcess=$true)]
param()
$ErrorActionPreference='Stop'
$directory=Join-Path $env:LOCALAPPDATA 'SpotXMinimizeGuard'
$exe=Join-Path $directory 'SpotifyWindowHelper.exe'
$key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$name='SpotXSpotifyWindowHelper'
if(-not $PSCmdlet.ShouldProcess($directory,'Stop helper and remove owned startup registration')){return}
if(Test-Path -LiteralPath $key){
    $property=(Get-ItemProperty -LiteralPath $key).PSObject.Properties[$name]
    if($property -and $property.Value -ceq ('"'+$exe+'"')){Remove-ItemProperty -LiteralPath $key -Name $name}
}
if(Test-Path -LiteralPath $directory){
    [IO.File]::WriteAllText((Join-Path $directory 'helper.stop'),'stop')
    [IO.File]::WriteAllText((Join-Path $directory 'stop.txt'),'stop')
    $deadline=(Get-Date).AddSeconds(20)
    do{
        $running=@(Get-Process SpotifyWindowHelper -ErrorAction SilentlyContinue | Where-Object Path -eq $exe)
        if(-not $running.Count){break}
        Start-Sleep -Milliseconds 250
    }while((Get-Date) -lt $deadline)
    if($running.Count){throw 'Helper did not stop; executable and recovery data retained.'}
    if(Test-Path -LiteralPath $exe){Remove-Item -LiteralPath $exe}
}
Write-Host 'Automatic window repairs removed. Fully exit Spotify to remove any current in-memory guard.'
