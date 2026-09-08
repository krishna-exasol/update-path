# The Windows half of tests/skills.sh, executed rather than grepped.
#
# tests/skills.sh asserts the PowerShell skill layer with awk and grep against
# exakit-common.ps1, because there is no pwsh on the machine this kit is
# developed on. That catches a deleted line and nothing else: a logic error
# that still reads correctly passes. Every fix in this layer - the
# EXAKIT_SKILL_ROOTS override, the prune of retired skills, the add-on gate -
# therefore shipped source-verified only.
#
# This file runs the real functions on a real filesystem, under the engine
# exakit.cmd actually invokes. It is driven from .github/workflows/windows-ps51.yml.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\skills.ps1
$ErrorActionPreference = "Stop"
$pass = 0
$fail = 0
function Check($label, $expected, $actual) {
    if ("$expected" -ceq "$actual") {
        Write-Host "  ok   $label = $actual"
        $script:pass++
    } else {
        # ${label}, not $label: PowerShell reads "$label:" as a drive-qualified
        # variable and refuses to parse the file at all.
        Write-Host "  FAIL ${label}: expected '$expected', got '$actual'"
        $script:fail++
    }
}

$repo = Split-Path -Parent $PSScriptRoot

# Definitions only, via the AST: exakit-common.ps1 has top-level statements
# (it creates the kit's directories when sourced) and none of them may run
# here. Same technique as tests/uninstall-ps.ps1.
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo "setup/lib/exakit-common.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "exakit-common.ps1 has parse errors" }
$fns = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $fns) { Invoke-Expression $f.Extent.Text }
foreach ($needed in @("Get-ExakitSkillRoots", "Get-ExakitSkillField", "Copy-ExakitSkill", "Remove-ExakitSkillCopy")) {
    if (-not (Get-Command $needed -ErrorAction SilentlyContinue)) { throw "$needed not found in exakit-common.ps1" }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-skills-" + [guid]::NewGuid())
$rootA = Join-Path $sandbox "claude-skills"
$rootB = Join-Path $sandbox "agents skills"   # a space, on purpose: that is why the separator is ';'
$src   = Join-Path $sandbox "src"
New-Item -ItemType Directory -Force -Path $rootA, $rootB, $src | Out-Null

Write-Host "Get-ExakitSkillRoots:"

# 1. The override, which is the whole reason this layer is testable at all.
$env:EXAKIT_SKILL_ROOTS = "$rootA;$rootB"
$roots = @(Get-ExakitSkillRoots)
Check "the override is honoured"        "2"     "$($roots.Count)"
Check "...first root"                   $rootA  "$($roots[0])"
Check "...second root, spaces intact"   $rootB  "$($roots[1])"

# 2. Whitespace and empty segments. A trailing ';' is what a hand-edited
# environment variable looks like, and an empty root would place skills at the
# filesystem root.
$env:EXAKIT_SKILL_ROOTS = " $rootA ; ; $rootB ;"
$roots = @(Get-ExakitSkillRoots)
Check "blank segments dropped, ends trimmed" "$rootA|$rootB" ($roots -join "|")

# 3. Unset: the two discovery folders under the profile home, never $HOME.
# On a redirected home those differ, and exapump/Claude Code read the profile.
Remove-Item Env:\EXAKIT_SKILL_ROOTS -ErrorAction SilentlyContinue
function Get-ExakitProfileHome { return "C:\fake-profile" }
$roots = @(Get-ExakitSkillRoots)
Check "default root count"  "2" "$($roots.Count)"
Check "default is .claude"  "C:\fake-profile\.claude\skills" "$($roots[0])"
Check "default is .agents"  "C:\fake-profile\.agents\skills" "$($roots[1])"

Write-Host "Get-ExakitSkillField:"

# UTF-8 without a BOM, because that is what the repo's SKILL.md files are and
# 5.1 would otherwise decode them as the system ANSI codepage. The em dash is
# the character that exposes it: every description in this kit carries one.
$skillMd = @(
    "---",
    "name: demo-skill",
    "description: A demo skill - with an em dash: " + [char]0x2014 + " and a colon.",
    "addon: dash-server",
    "---",
    "",
    "# Body"
)
$one = Join-Path $src "demo-skill"
New-Item -ItemType Directory -Force -Path $one | Out-Null
[System.IO.File]::WriteAllLines((Join-Path $one "SKILL.md"), $skillMd, (New-Object System.Text.UTF8Encoding($false)))

Check "name is read" "demo-skill" (Get-ExakitSkillField -Path (Join-Path $one "SKILL.md") -Field "name")
$desc = Get-ExakitSkillField -Path (Join-Path $one "SKILL.md") -Field "description"
Check "the em dash survives 5.1's decoding" "yes" $(if ($desc -match ([char]0x2014)) { "yes" } else { "no ($desc)" })
Check "a description with a colon is not truncated" "yes" $(if ($desc.EndsWith("and a colon.")) { "yes" } else { "no ($desc)" })
Check "a missing field is empty, not an error" "" (Get-ExakitSkillField -Path (Join-Path $one "SKILL.md") -Field "nosuch")
Check "a missing file is empty, not an error"  "" (Get-ExakitSkillField -Path (Join-Path $src "gone\SKILL.md") -Field "name")

Write-Host "Copy-ExakitSkill / Remove-ExakitSkillCopy:"

$env:EXAKIT_SKILL_ROOTS = "$rootA;$rootB"
Copy-ExakitSkill -Source $one -Name "demo-skill"
Check "placed in root A" "True" "$(Test-Path (Join-Path $rootA 'demo-skill\SKILL.md'))"
Check "placed in root B" "True" "$(Test-Path (Join-Path $rootB 'demo-skill\SKILL.md'))"

# A skill the user placed themselves. The kit removes only what it recorded,
# so this one has to survive every operation below.
$mine = Join-Path $rootA "my-own-skill"
New-Item -ItemType Directory -Force -Path $mine | Out-Null
Set-Content -Path (Join-Path $mine "SKILL.md") -Value "---`nname: my-own-skill`n---" -Encoding Ascii

# Re-placing must replace, not merge: a file the new version dropped cannot
# survive the copy.
Set-Content -Path (Join-Path $rootA "demo-skill\stale.md") -Value "old" -Encoding Ascii
Copy-ExakitSkill -Source $one -Name "demo-skill"
Check "a re-place drops a file the new version does not carry" "False" `
    "$(Test-Path (Join-Path $rootA 'demo-skill\stale.md'))"

Remove-ExakitSkillCopy -Name "demo-skill"
Check "retired from root A" "False" "$(Test-Path (Join-Path $rootA 'demo-skill'))"
Check "retired from root B" "False" "$(Test-Path (Join-Path $rootB 'demo-skill'))"
Check "the user's own skill is untouched" "True" "$(Test-Path (Join-Path $mine 'SKILL.md'))"

# Removing something that was never there is not an error: uninstall runs it
# for every recorded name, and a machine that lost one by hand must not stop.
Remove-ExakitSkillCopy -Name "never-existed"
Check "removing an absent skill is a no-op" "True" "True"

Remove-Item Env:\EXAKIT_SKILL_ROOTS -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "skills (ps): $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
