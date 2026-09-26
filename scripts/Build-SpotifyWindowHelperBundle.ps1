# Regenerate or validate the reviewed source bundle embedded in run.ps1.
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $scriptDirectory = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptDirectory = Split-Path -Parent $PSCommandPath
    }
    $RepositoryRoot = Split-Path -Parent $scriptDirectory
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$runPath = Join-Path $RepositoryRoot 'run.ps1'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$runText = [IO.File]::ReadAllText($runPath)
$beginMarker = '# BEGIN GENERATED WINDOW HELPER BUNDLE'
$endMarker = '# END GENERATED WINDOW HELPER BUNDLE'
$begin = [regex]::Matches($runText, ('(?m)^' + [regex]::Escape($beginMarker) + '(?=\r?$)'))
$end = [regex]::Matches($runText, ('(?m)^' + [regex]::Escape($endMarker) + '(?=\r?$)'))
if ($begin.Count -ne 1 -or $end.Count -ne 1 -or $end[0].Index -le $begin[0].Index) {
    throw 'run.ps1 must contain exactly one ordered generated window-helper marker pair.'
}
$regionStart = $begin[0].Index
$regionEnd = $end[0].Index + $endMarker.Length
$region = $runText.Substring($regionStart, $regionEnd - $regionStart)
$names = @(
    'Install-SpotifyWindowHelper.ps1',
    'SpotifyFrameGuard.Native.cs',
    'SpotifyWindowHelper.cs',
    'Uninstall-SpotifyWindowHelper.ps1'
)
function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}
$files = [ordered]@{}
foreach ($name in $names) {
    $source = [IO.File]::ReadAllText((Join-Path (Join-Path $RepositoryRoot 'scripts') $name))
    if ($source.Length -gt 0 -and $source[0] -eq [char]0xFEFF) { $source = $source.Substring(1) }
    $source = $source.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = $utf8.GetBytes($source)
    $files[$name] = [ordered]@{
        Sha256 = Get-Sha256 $bytes
        ContentBase64 = [Convert]::ToBase64String($bytes)
    }
}
if ($Check) {
    $pattern = '\A' + [regex]::Escape($beginMarker) + '\r?\nfunction Get-SpotXWindowHelperBundle\s*\{\s*return @''\r?\n(?<payload>[A-Za-z0-9+/=\r\n]+)\r?\n''@\s*\}\r?\n' + [regex]::Escape($endMarker) + '\z'
    $match = [regex]::Match($region, $pattern)
    if (-not $match.Success) { throw 'The generated region does not contain the expected literal bundle function.' }
    $compressed = [Convert]::FromBase64String($match.Groups['payload'].Value)
    $input = New-Object IO.MemoryStream(,$compressed)
    $output = New-Object IO.MemoryStream
    $gzip = New-Object IO.Compression.GZipStream($input, [IO.Compression.CompressionMode]::Decompress)
    try {
        $buffer = New-Object byte[] 8192
        while (($count = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($output.Length + $count -gt 4194304) { throw 'Decoded bundle exceeds the 4 MB source limit.' }
            $output.Write($buffer, 0, $count)
        }
        $manifest = $utf8.GetString($output.ToArray()) | ConvertFrom-Json
    }
    finally { $gzip.Dispose(); $input.Dispose(); $output.Dispose() }
    if (($manifest.PSObject.Properties.Name -join ',') -cne 'SchemaVersion,Files' -or
        ($manifest.SchemaVersion -isnot [int] -and $manifest.SchemaVersion -isnot [long]) -or $manifest.SchemaVersion -ne 1) {
        throw 'The embedded bundle schema is invalid.'
    }
    if (($manifest.Files.PSObject.Properties.Name -join "`n") -cne ($names -join "`n")) {
        throw 'The embedded bundle must contain exactly the four canonical files in order.'
    }
    foreach ($name in $names) {
        $entry = $manifest.Files.PSObject.Properties[$name].Value
        if (($entry.PSObject.Properties.Name -join ',') -cne 'Sha256,ContentBase64') { throw "Invalid bundle entry: $name" }
        $decoded = [Convert]::FromBase64String($entry.ContentBase64)
        if ($entry.Sha256 -cne (Get-Sha256 $decoded) -or $entry.Sha256 -cne $files[$name].Sha256 -or
            [Convert]::ToBase64String($decoded) -cne $files[$name].ContentBase64) {
            throw "Embedded bundle differs from the canonical source: $name"
        }
    }
    'Window-helper bundle is current (four canonical sources).'
    return
}
$json = [ordered]@{ SchemaVersion = 1; Files = $files } | ConvertTo-Json -Depth 5 -Compress
$jsonBytes = $utf8.GetBytes($json)
$stream = New-Object IO.MemoryStream
$gzip = New-Object IO.Compression.GZipStream($stream, [IO.Compression.CompressionMode]::Compress, $true)
try { $gzip.Write($jsonBytes, 0, $jsonBytes.Length) }
finally { $gzip.Dispose() }
try { $base64 = [Convert]::ToBase64String($stream.ToArray()) }
finally { $stream.Dispose() }
$newline = if ($runText.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = for ($offset = 0; $offset -lt $base64.Length; $offset += 120) {
    $base64.Substring($offset, [Math]::Min(120, $base64.Length - $offset))
}
$generated = @(
    $beginMarker,
    'function Get-SpotXWindowHelperBundle {',
    "    return @'",
    ($lines -join $newline),
    "'@",
    '}',
    $endMarker
) -join $newline
$updated = $runText.Substring(0, $regionStart) + $generated + $runText.Substring($regionEnd)
[IO.File]::WriteAllText($runPath, $updated, $utf8)
'Updated the generated window-helper bundle in run.ps1.'
