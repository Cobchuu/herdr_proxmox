$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$releaseDestination = Join-Path $PWD 'web/public'
function Invoke-Checked {
    param([scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Build command failed with exit code $LASTEXITCODE" }
}
# Initialize separately: a fresh SDK may print first-run notices before JSON.
Invoke-Checked { flutter config --no-analytics }
$versionJson = & flutter --version --machine
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the Flutter version' }
$version = ($versionJson | ConvertFrom-Json).frameworkVersion
$requiredVersion = (Get-Content .fvmrc -Raw | ConvertFrom-Json).flutter
if ($version -ne $requiredVersion) { throw "Flutter $requiredVersion required, found $version" }
Push-Location web/dashboard_state
try {
    Invoke-Checked { flutter pub get }
} finally { Pop-Location }
Push-Location web/dashboard
try {
    Invoke-Checked { flutter pub get }
    Invoke-Checked { flutter analyze }
    Invoke-Checked { flutter test }
} finally { Pop-Location }
Push-Location web/jaspr_dashboard
try {
    Invoke-Checked { dart pub get }
    Invoke-Checked { dart analyze lib web vendor/juice/lib test }
    Invoke-Checked { dart test --platform vm }
    New-Item -ItemType Directory -Force build/release | Out-Null
    Invoke-Checked { dart compile js web/main.dart -O2 -o build/release/main.dart.js }
    Copy-Item web/index.html,web/styles.css,web/icons.svg build/release -Force
    Copy-Item web/css,web/vendor build/release -Recurse -Force
    $expectedDestination = [System.IO.Path]::GetFullPath((Join-Path $PWD '../public'))
    if ([System.IO.Path]::GetFullPath($releaseDestination) -ne $expectedDestination) { throw 'Unexpected release destination' }
    if (Test-Path -LiteralPath $releaseDestination) { Remove-Item -LiteralPath $releaseDestination -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $releaseDestination 'dashboard') | Out-Null
    Copy-Item build/release/main.dart.js*,build/release/index.html,build/release/styles.css,build/release/icons.svg ../public/dashboard -Force
    Copy-Item build/release/css,build/release/vendor ../public/dashboard -Recurse -Force
    Copy-Item ../public/dashboard/* ../public -Recurse -Force
} finally { Pop-Location }
