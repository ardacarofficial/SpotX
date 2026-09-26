# Exercises only the extracted bundle functions; never runs run.ps1's installer.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runPath = Join-Path $repoRoot 'run.ps1'
$runTokens = $null
$runErrors = $null
$runAst = [System.Management.Automation.Language.Parser]::ParseFile($runPath, [ref]$runTokens, [ref]$runErrors)
if ($runErrors.Count) { throw ('run.ps1 parse failed: ' + $runErrors[0].Message) }

function Get-RequiredFunctionAst([string] $Name) {
    $matches = @($runAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Name -ceq $Name })
    if ($matches.Count -ne 1) { throw "Expected exactly one $Name definition in run.ps1; found $($matches.Count)." }
    return $matches[0]
}

$getBundleAst = Get-RequiredFunctionAst 'Get-SpotXWindowHelperBundle'
$expandBundleAst = Get-RequiredFunctionAst 'Expand-SpotXWindowHelperBundle'
. ([ScriptBlock]::Create($getBundleAst.Extent.Text))
. ([ScriptBlock]::Create($expandBundleAst.Extent.Text))

$expectedNames = @(
    'Install-SpotifyWindowHelper.ps1',
    'Uninstall-SpotifyWindowHelper.ps1',
    'SpotifyWindowHelper.cs',
    'SpotifyFrameGuard.Native.cs'
)
$sourceDirectory = Join-Path $repoRoot 'scripts'
$canonical = [ordered]@{}
foreach ($name in $expectedNames) {
    $path = Join-Path $sourceDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Canonical source missing: $path" }
    # The bundle builder emits UTF-8 without a BOM and normalizes all line endings to LF.
    $text = [IO.File]::ReadAllText($path)
    $text = $text -replace "`r`n?", "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
    $canonical[$name] = [pscustomobject]@{
        Sha256 = $hash
        ContentBase64 = [Convert]::ToBase64String($bytes)
    }
}

function ConvertTo-TestBundle($Payload) {
    $json = ConvertTo-Json -InputObject $Payload -Depth 8 -Compress
    $raw = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $compressed = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionMode]::Compress, $true)
    try { $gzip.Write($raw, 0, $raw.Length) }
    finally { $gzip.Dispose() }
    try { return [Convert]::ToBase64String($compressed.ToArray()) }
    finally { $compressed.Dispose() }
}

function New-TestPayload($Files, [int] $SchemaVersion = 1) {
    return [pscustomobject]@{ SchemaVersion = $SchemaVersion; Files = $Files }
}

function New-TestDestination([string] $Name) {
    $path = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    return $path
}

function Assert-RejectedBeforeWrites([string] $Name, [string] $Bundle, [string] $ExpectedMessagePattern = '') {
    $destination = New-TestDestination $Name
    $rejected = $false
    $failureMessage = ''
    try { Expand-SpotXWindowHelperBundle -Bundle $Bundle -Destination $destination }
    catch { $rejected = $true; $failureMessage = $_.Exception.Message }
    if (-not $rejected) { throw "Malformed bundle '$Name' was accepted." }
    if ($ExpectedMessagePattern -and $failureMessage -notmatch $ExpectedMessagePattern) {
        throw "Malformed bundle '$Name' failed for an unexpected reason: $failureMessage"
    }
    $remaining = @(Get-ChildItem -LiteralPath $destination -Force)
    if ($remaining.Count -ne 0) { throw "Malformed bundle '$Name' wrote files before rejection." }
}

function Assert-FilesMatchCanonical([string] $Destination, [string] $Label) {
    $actualFiles = @(Get-ChildItem -LiteralPath $Destination -File | ForEach-Object Name | Sort-Object)
    $expectedSorted = @($expectedNames | Sort-Object)
    if (($actualFiles -join "`n") -cne ($expectedSorted -join "`n")) { throw "$Label produced an unexpected file list." }
    foreach ($name in $expectedNames) {
        $path = Join-Path $Destination $name
        $bytes = [IO.File]::ReadAllBytes($path)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
        finally { $sha.Dispose() }
        if ($hash -cne $canonical[$name].Sha256) { throw "$Label payload differs from canonical $name." }
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SpotX-WindowHelperBundle-Test-' + [Guid]::NewGuid().ToString('N'))
$testRootFull = [IO.Path]::GetFullPath($testRoot)
New-Item -ItemType Directory -Path $testRootFull -ErrorAction Stop | Out-Null

try {
    # The synthetic valid payload uses the repository's exact canonical files.
    $validBundle = ConvertTo-TestBundle (New-TestPayload $canonical)
    $validDestination = New-TestDestination 'valid'
    Expand-SpotXWindowHelperBundle -Bundle $validBundle -Destination $validDestination
    Assert-FilesMatchCanonical $validDestination 'Synthetic valid bundle'
    'PASS: valid bundle expands to exactly four canonical source files'

    $badSchema = ConvertTo-TestBundle (New-TestPayload $canonical 2)
    Assert-RejectedBeforeWrites 'bad-schema' $badSchema 'schema'

    $traversalFiles = [ordered]@{}
    foreach ($name in $expectedNames) {
        if ($name -eq 'SpotifyFrameGuard.Native.cs') { $traversalFiles['..\escaped.txt'] = $canonical[$name] }
        else { $traversalFiles[$name] = $canonical[$name] }
    }
    $traversalBundle = ConvertTo-TestBundle (New-TestPayload $traversalFiles)
    Assert-RejectedBeforeWrites 'traversal-name' $traversalBundle 'filename'
    if (Test-Path -LiteralPath (Join-Path $testRoot 'escaped.txt')) { throw 'Traversal bundle wrote outside its staging directory.' }

    $extraFiles = [ordered]@{}
    foreach ($name in $expectedNames) { $extraFiles[$name] = $canonical[$name] }
    $extraFiles['unexpected.txt'] = [pscustomobject]@{ Sha256 = ('0' * 64); ContentBase64 = [Convert]::ToBase64String([byte[]]@()) }
    $extraBundle = ConvertTo-TestBundle (New-TestPayload $extraFiles)
    Assert-RejectedBeforeWrites 'extra-name' $extraBundle 'file count'

    $badHashFiles = [ordered]@{}
    foreach ($name in $expectedNames) {
        $entry = $canonical[$name]
        if ($name -eq 'SpotifyFrameGuard.Native.cs') {
            $entry = [pscustomobject]@{ Sha256 = ('0' * 64); ContentBase64 = $entry.ContentBase64 }
        }
        $badHashFiles[$name] = $entry
    }
    $badHashBundle = ConvertTo-TestBundle (New-TestPayload $badHashFiles)
    Assert-RejectedBeforeWrites 'bad-hash' $badHashBundle 'hash mismatch'

    $badInnerBase64Files = [ordered]@{}
    foreach ($name in $expectedNames) {
        $entry = $canonical[$name]
        if ($name -eq 'SpotifyFrameGuard.Native.cs') {
            $entry = [pscustomobject]@{ Sha256 = $entry.Sha256; ContentBase64 = '%%%not-base64%%%' }
        }
        $badInnerBase64Files[$name] = $entry
    }
    $badInnerBundle = ConvertTo-TestBundle (New-TestPayload $badInnerBase64Files)
    Assert-RejectedBeforeWrites 'bad-inner-base64' $badInnerBundle

    Assert-RejectedBeforeWrites 'bad-outer-base64' '%%not-base64%%'
    'PASS: schema, traversal, extra name, hash, and Base64 failures write no files'

    $embeddedBundle = [string](Get-SpotXWindowHelperBundle)
    $embeddedBundle = $embeddedBundle -replace '\s', ''
    if ([string]::IsNullOrWhiteSpace($embeddedBundle)) {
        throw 'Get-SpotXWindowHelperBundle returned no production payload.'
    }
    $embeddedDestination = New-TestDestination 'embedded'
    Expand-SpotXWindowHelperBundle -Bundle $embeddedBundle -Destination $embeddedDestination
    Assert-FilesMatchCanonical $embeddedDestination 'Embedded production bundle'
    'PASS: embedded production bundle matches all four canonical repository files'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92) + [IO.Path]::DirectorySeparatorChar
    if ($testRootFull.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($testRootFull).StartsWith('SpotX-WindowHelperBundle-Test-', [StringComparison]::Ordinal) -and
        (Test-Path -LiteralPath $testRootFull)) {
        Remove-Item -LiteralPath $testRootFull -Recurse -Force
    }
}
