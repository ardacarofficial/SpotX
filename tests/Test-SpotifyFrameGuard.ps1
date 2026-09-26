# Executes the generated wrapper against synthetic data in this test process.
# Does not open, modify or require Spotify.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw '64-bit PowerShell is required.' }
Add-Type -Path (Join-Path $PSScriptRoot '../scripts/SpotifyFrameGuard.Native.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'SpotifyFrameGuard.Abi.cs')
$code = [SpotifyFrameGuardNative]::BuildWrapper(0x1234, [GuardAbiTest]::Predicate())
[GuardAbiTest]::Run($code)

# Invalid recovery data must be rejected before opening any target process.
$moduleBase = [long]0x10000000
$site = $moduleBase + 0x1D1312B
$page = [long]0x12000000
$original = '488B4E60E83CF75800'
$patch = '4889F190E8' + [BitConverter]::ToString([BitConverter]::GetBytes([int]($page - $site - 9))).Replace('-', '')
$cases = @(
    @(($site + 1), $page, $original, $patch, 'verified CEF module'),
    @($site, $page, '000000000000000000', $patch, 'verified CEF module'),
    @($site, $page, $original, '000000000000000000', 'invalid format'),
    @($site, ($page + 0x10000), $original, $patch, 'registered code page')
)
foreach ($case in $cases) {
    $rejected = $false
    try { [SpotifyFrameGuardNative]::Undo(-1, -1, 0, $case[0], $case[1], $case[2], $case[3], $moduleBase) }
    catch {
        if ($_.Exception.ToString() -notmatch [regex]::Escape($case[4])) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Invalid recovery state was accepted.' }
}
'PASS: 4 invalid recovery states rejected before opening a process'
