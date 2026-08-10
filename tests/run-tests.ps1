<#
    Moodle Quarters test runner.

    Boots Project Zomboid's own Kahlua VM outside the game, stubs the parts of the game
    API the mod touches, and runs the specs in tests/specs against the real mod source.
    No game launch, no manual clicking.

    Usage:  pwsh tests/run-tests.ps1
#>

$ErrorActionPreference = 'Stop'

function Find-GameDir {
    # An explicit override wins, for an install this does not know about.
    if ($env:PZ_DIR) { return $env:PZ_DIR }

    # Otherwise walk every Steam library listed in libraryfolders.vdf, then fall back to
    # the usual suspects. Beats hardcoding one machine's drive letter.
    $candidates = @()
    foreach ($steam in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) {
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s*"([^"]+)"')) {
                $candidates += Join-Path ($m.Groups[1].Value -replace '\\\\', '\') 'steamapps\common\ProjectZomboid'
            }
        }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Name) {
        $candidates += "${drive}:\SteamLibrary\steamapps\common\ProjectZomboid"
        $candidates += "${drive}:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"
    }

    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'projectzomboid.jar')) { return $c }
    }
    throw "Could not find a Project Zomboid install. Set PZ_DIR to its folder."
}

function Find-Jdk {
    $candidates = @(
        'C:\Program Files\Eclipse Adoptium\jdk-*\bin',
        'C:\Program Files\*\jdk*\bin',
        'C:\Program Files\JetBrains\*\jbr\bin'
    )
    foreach ($pattern in $candidates) {
        $hit = Get-ChildItem $pattern -ErrorAction SilentlyContinue |
               Where-Object { Test-Path (Join-Path $_.FullName 'javac.exe') } |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "No JDK with javac found. The JRE bundled with the game cannot compile the runner."
}

$GameDir = Find-GameDir
$Jar     = Join-Path $GameDir 'projectzomboid.jar'
# The mod root is the repository itself: the shipped build 42 tree is 42/media, which is
# where TestRunner resolves texture paths and script folders from.
$Root    = Split-Path -Parent $PSScriptRoot
$Harness = Join-Path $PSScriptRoot 'harness'
$Specs   = Join-Path $PSScriptRoot 'specs'
$Build   = Join-Path $PSScriptRoot 'build'

if (-not (Test-Path $Jar)) { throw "Game jar not found at $Jar" }
$JdkBin = Find-Jdk
$Javac  = Join-Path $JdkBin 'javac.exe'
$Java   = Join-Path $JdkBin 'java.exe'

$VersionFile = Join-Path $env:USERPROFILE 'Zomboid\version.txt'
$Build42 = if (Test-Path $VersionFile) { (Get-Content $VersionFile | Select-Object -First 1) } else { 'unknown' }

Write-Host "Game    $GameDir"
Write-Host "Build   $Build42"
Write-Host "JDK     $JdkBin"
Write-Host ""

# --- art ------------------------------------------------------------------
# TestRunner resolves literal getTexture paths, and every path this mod asks for is
# built with string.format, so the files themselves are checked here instead. A missing
# one is not an error at runtime: the texture is null and nothing draws.

$ArtFailures = 0
$Lua = Get-Content (Join-Path $Root '42\media\lua\client\MoodleQuarters.lua') -Raw

foreach ($size in [regex]::Matches($Lua, 'MQ\.sizes\s*=\s*\{([^}]*)\}')[0].Groups[1].Value -split ',') {
    $size = $size.Trim()
    if (-not $size) { continue }
    foreach ($kind in @('good', 'bad')) {
        foreach ($level in 1..4) {
            $art = Join-Path $Root "42\media\ui\MoodleQuarters\$size\${kind}_$level.png"
            if (-not (Test-Path $art)) {
                $ArtFailures++
                Write-Host "  FAIL  missing level art: 42/media/ui/MoodleQuarters/$size/${kind}_$level.png"
            }
        }
    }
    # The moodle symbols stay vanilla, so each one has to exist in the install.
    foreach ($m in [regex]::Matches($Lua, 'icon\s*=\s*"([^"]+)"')) {
        $icon = Join-Path $GameDir "media\ui\Moodles\$size\$($m.Groups[1].Value).png"
        if (-not (Test-Path $icon)) {
            $ArtFailures++
            Write-Host "  FAIL  the install has no media/ui/Moodles/$size/$($m.Groups[1].Value).png"
        }
    }
}

if ($ArtFailures -gt 0) {
    Write-Host ""
    Write-Host "$ArtFailures ART FAILURE(S). Run: python tools/generate_plates.py"
    exit 1
}

# --- compile the runner ----------------------------------------------------

New-Item -ItemType Directory -Force -Path $Build | Out-Null
$RunnerSrc = Join-Path $Harness 'TestRunner.java'
$RunnerCls = Join-Path $Build 'TestRunner.class'

if (-not (Test-Path $RunnerCls) -or (Get-Item $RunnerSrc).LastWriteTime -gt (Get-Item $RunnerCls).LastWriteTime) {
    Write-Host "Compiling test runner..."
    & $Javac -nowarn -cp $Jar -d $Build $RunnerSrc
    if ($LASTEXITCODE -ne 0) { throw "Failed to compile TestRunner.java" }
}

# --- assemble the load order -----------------------------------------------
# Stubs first, then the real PZAPI, then the assertions, then the mod under test, then
# the specs. Order matters: each layer depends on the last.

$LoadFiles = @()
$LoadFiles += Join-Path $Harness 'pz_stubs.lua'
$LoadFiles += Join-Path $Harness 'mq_stubs.lua'
$LoadFiles += Join-Path $GameDir 'media\lua\client\PZAPI\ModOptions.lua'
$LoadFiles += Join-Path $Harness 'test_lib.lua'

foreach ($tree in @('shared', 'client', 'server')) {
    $dir = Join-Path $Root "42\media\lua\$tree"
    if (Test-Path $dir) {
        $LoadFiles += Get-ChildItem $dir -Filter *.lua -Recurse | Sort-Object Name | ForEach-Object { $_.FullName }
    }
}

$LoadFiles += Get-ChildItem $Specs -Filter *_spec.lua | Sort-Object Name | ForEach-Object { $_.FullName }

foreach ($f in $LoadFiles) {
    if (-not (Test-Path $f)) { throw "Missing file in load order: $f" }
}

# --- run -------------------------------------------------------------------
# Kahlua resolves stdlib.lua against the working directory, so run from the game dir.

Push-Location $GameDir
try {
    & $Java -cp "$Jar;$Build" TestRunner $GameDir $Root @LoadFiles
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

exit $code
