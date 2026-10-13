# check-ps1.ps1 - ASCII + parse validation, run before any smoke script.
#
# Two independent readers on purpose: the legacy PSParser tokenizer and the modern
# language parser. A script that only one of them likes has a real problem.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'
$resolved = (Resolve-Path -LiteralPath $Path).Path
$fail = @()

# 1) encoding gate: every byte must be ASCII, otherwise the script means different
#    things depending on who reads it.
$bytes = [IO.File]::ReadAllBytes($resolved)
$badIdx = @()
for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $badIdx += $i } }
if ($badIdx.Count) {
    $fail += ('non-ascii bytes: ' + $badIdx.Count + ' first at ' + ($badIdx[0]))
} else {
    Write-Host ('ascii ok, bytes=' + $bytes.Length)
}

$text = [IO.File]::ReadAllText($resolved)

# 2) legacy tokenizer
$errs1 = $null
$toks = [System.Management.Automation.PSParser]::Tokenize($text, [ref]$errs1)
Write-Host ('psparser tokens=' + $toks.Count + ' errors=' + $errs1.Count)
foreach ($e in $errs1) { $fail += ('psparser: ' + $e.Message) }

# 3) modern parser
$errs2 = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs2)
Write-Host ('language parser errors=' + $errs2.Count)
foreach ($e in $errs2) { $fail += ('parser: ' + $e.Message + ' @line ' + $e.Extent.StartLineNumber) }

# 4) defined-but-never-called functions are usually a copy/paste leftover
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs2)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $uses = ([regex]::Matches($text, ('(?i)(?<![\w\-])' + [regex]::Escape($f.Name) + '(?![\w\-])'))).Count
    Write-Host ('function ' + $f.Name + ' occurrences=' + $uses)
    if ($uses -lt 2) { $fail += ('unused function: ' + $f.Name) }
}

Write-Host ''
if ($fail.Count) {
    Write-Host ('CHECK FAILED (' + $fail.Count + '):')
    foreach ($m in $fail) { Write-Host (' - ' + $m) }
    exit 1
}
Write-Host 'CHECK OK'
exit 0
