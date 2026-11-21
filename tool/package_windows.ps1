#Requires -Version 7.0
<#
.SYNOPSIS
Package an already-built Windows x64 Release, with app-local MSVC runtimes.
.EXAMPLE
pwsh -File tool/package_windows.ps1 -SmokeTest
.NOTES
Run flutter build windows --release first.
This script does not install tools, build the app, or publish a release.
#>
[CmdletBinding()]
param(
    [string]$ProjectDir = (Split-Path -Parent $PSScriptRoot),
    [string]$BuildDir,
    [string]$OutputDir,
    [string]$RuntimeDir,
    [switch]$SmokeTest,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows packaging must run on Windows with PowerShell 7.' }
$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
if (-not $BuildDir) { $BuildDir = Join-Path $ProjectDir 'build/windows/x64/runner/Release' }
if (-not $OutputDir) { $OutputDir = Join-Path $ProjectDir 'releases/windows' }
$BuildDir = (Resolve-Path -LiteralPath $BuildDir).Path
$OutputDir = [IO.Path]::GetFullPath($OutputDir)

function Assert-RegularFile([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a regular file: $Path"
    }
    if ($item.Length -eq 0) { throw "Empty required file: $Path" }
}

function Assert-X64Pe([string]$Path) {
    Assert-RegularFile $Path
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) {
            throw "Missing MZ header: $Path"
        }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 26) { throw "Invalid PE offset: $Path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "Expected a Windows AMD64 PE: $Path"
        }
        $stream.Position = $peOffset + 24
        if ($reader.ReadUInt16() -ne 0x20b) { throw "Expected a PE32+ image: $Path" }
    } finally {
        $reader.Dispose()
    }
}

function Find-X64Runtime {
    if ($RuntimeDir) { return (Resolve-Path -LiteralPath $RuntimeDir).Path }
    $roots = [Collections.Generic.List[string]]::new()
    if ($env:VCToolsRedistDir) { $roots.Add($env:VCToolsRedistDir) }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0) { throw 'vswhere failed to locate Visual Studio C++ tools.' }
        if ($installation) { $roots.Add((Join-Path $installation 'VC/Redist/MSVC')) }
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $candidates = Get-ChildItem -LiteralPath $root -Directory -Recurse -Filter 'Microsoft.VC*.CRT' |
            Where-Object { $_.FullName -match '[\\/]x64[\\/]Microsoft\.VC\d+\.CRT$' } |
            Sort-Object -Property @{ Expression = {
                if ($_.FullName -match '[\\/]MSVC[\\/](\d+\.\d+\.\d+)') {
                    [version]$Matches[1]
                } else { [version]'0.0' }
            }; Descending = $true }
        foreach ($candidate in $candidates) {
            if ((Test-Path (Join-Path $candidate.FullName 'msvcp140.dll')) -and
                (Test-Path (Join-Path $candidate.FullName 'vcruntime140.dll')) -and
                (Test-Path (Join-Path $candidate.FullName 'vcruntime140_1.dll'))) {
                return $candidate.FullName
            }
        }
    }
    throw 'MSVC x64 redistributable CRT directory not found. Pass -RuntimeDir with its Microsoft.VC*.CRT directory.'
}

$pubspec = Get-Content -LiteralPath (Join-Path $ProjectDir 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*[''" ]*(\d+\.\d+\.\d+)\+(\d+)[''" ]*\s*$') {
    throw 'pubspec.yaml must contain a numeric major.minor.patch+build version.'
}
$releaseVersion = $Matches[1]
$buildNumber = $Matches[2]
$version = "$releaseVersion+$buildNumber"
$packageName = "ESP-INK-$releaseVersion-windows-x64"
$archivePath = Join-Path $OutputDir "$packageName.zip"
$checksumPath = "$archivePath.sha256"
$reportPath = Join-Path $OutputDir "$packageName.build.json"
foreach ($path in @($archivePath, $checksumPath, $reportPath)) {
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "Output already exists; use -Force to replace this version: $path"
    }
}

$runtimeSource = Find-X64Runtime
$temporaryRoot = Join-Path $OutputDir ('.windows-package-' + [guid]::NewGuid().ToString('N'))
$bundle = Join-Path $temporaryRoot $packageName
$temporaryZip = Join-Path $temporaryRoot 'package.zip'
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
try {
    $linked = Get-ChildItem -LiteralPath $BuildDir -Recurse -Force |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1
    if ($linked) { throw "Release bundle must not contain links: $($linked.FullName)" }
    Get-ChildItem -LiteralPath $BuildDir -Force | Copy-Item -Destination $bundle -Recurse -Force
    Get-ChildItem -LiteralPath $runtimeSource -File -Filter '*.dll' |
        Copy-Item -Destination $bundle -Force

    $requiredFiles = @(
        'ESP-INK.exe', 'flutter_windows.dll', 'file_selector_windows_plugin.dll',
        'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
        'data/icudtl.dat', 'data/app.so',
        'data/flutter_assets/assets/fonts/NotoSansSC-Regular.otf',
        'data/flutter_assets/assets/fonts/NotoSerifSC-Regular.otf',
        'data/flutter_assets/assets/fonts/NotoSansMonoSC-Regular.otf'
    )
    if ($pubspec -match '(?m)^\s+universal_ble:') { $requiredFiles += 'universal_ble_plugin.dll' }
    foreach ($relative in $requiredFiles) { Assert-RegularFile (Join-Path $bundle $relative) }
    $peFiles = @(Get-ChildItem -LiteralPath $bundle -Recurse -File |
        Where-Object { $_.Extension -in @('.exe', '.dll') })
    foreach ($file in $peFiles) { Assert-X64Pe $file.FullName }
    $exe = Join-Path $bundle 'ESP-INK.exe'
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    $expectedParts = @($releaseVersion.Split('.') + $buildNumber) | ForEach-Object { [int]$_ }
    if ($info.FileMajorPart -ne $expectedParts[0] -or
        $info.FileMinorPart -ne $expectedParts[1] -or
        $info.FileBuildPart -ne $expectedParts[2] -or
        $info.FilePrivatePart -ne $expectedParts[3] -or
        $info.ProductName -ne 'ESP-INK' -or $info.ProductVersion -ne $version) {
        throw "PE product/version does not match pubspec.yaml ($version): $($info | Out-String)"
    }
    $licenses = Join-Path $bundle 'licenses'
    New-Item -ItemType Directory -Path $licenses | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectDir 'assets/fonts/LICENSE-Noto.txt') -Destination $licenses

    $report = [ordered]@{
        product = 'ESP-INK'; version = $version; target = 'windows-x64'
        source_commit = $env:GITHUB_SHA; build_utc = [DateTime]::UtcNow.ToString('o')
        executable = 'ESP-INK.exe'; pe_machine = '0x8664'; pe_format = 'PE32+'
        file_version = $info.FileVersion; product_version = $info.ProductVersion
        verified_pe_files = @($peFiles | ForEach-Object { [IO.Path]::GetRelativePath($bundle, $_.FullName).Replace('\', '/') })
        runtime_files = @(Get-ChildItem -LiteralPath $runtimeSource -File -Filter '*.dll' | ForEach-Object { $_.Name })
        startup_verification_report = "$packageName.build.json (distributed alongside the ZIP)"
        jvm_requirement = 'none; Android-only optional JNI target is disabled for Windows'
        validation_scope = 'PE headers, version, bundle completeness, independent ZIP extraction and SHA256; startup smoke when requested. No hardware/BLE acceptance.'
    }
    $reportJson = $report | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $bundle 'BUILD-INFO.json') -Value $reportJson -Encoding utf8NoBOM
    $files = @(Get-ChildItem -LiteralPath $bundle -File -Recurse | Sort-Object FullName)
    $hashes = [ordered]@{}
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($bundle, $file.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest = @($hashes.GetEnumerator() | ForEach-Object { "$($_.Value)  $($_.Key)" })
    Set-Content -LiteralPath (Join-Path $bundle 'SHA256SUMS') -Value $manifest -Encoding utf8NoBOM
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $temporaryZip, [IO.Compression.CompressionLevel]::Optimal, $true)
    $extraction = Join-Path $temporaryRoot '解压 验证'
    [IO.Compression.ZipFile]::ExtractToDirectory($temporaryZip, $extraction)
    $extractedBundle = Join-Path $extraction $packageName
    if (@(Get-ChildItem -LiteralPath $extractedBundle -Recurse -File).Count -ne $hashes.Count + 1) {
        throw 'Extracted archive has an unexpected file count.'
    }
    foreach ($entry in $hashes.GetEnumerator()) {
        $actual = (Get-FileHash -LiteralPath (Join-Path $extractedBundle $entry.Key) -Algorithm SHA256).Hash
        if ($actual -ne $entry.Value) { throw "Extracted file checksum mismatch: $($entry.Key)" }
    }
    # Exercise the verified ZIP extraction, including a Unicode path with spaces.
    $smokeExe = Join-Path $extractedBundle 'ESP-INK.exe'
    $smoke = 'not_run'
    if ($SmokeTest) {
        $smokeStdout = Join-Path $temporaryRoot 'startup.stdout.log'
        $smokeStderr = Join-Path $temporaryRoot 'startup.stderr.log'
        $process = Start-Process -FilePath $smokeExe -WorkingDirectory $extractedBundle -PassThru `
            -RedirectStandardOutput $smokeStdout -RedirectStandardError $smokeStderr
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            do {
                Start-Sleep -Milliseconds 250
                $process.Refresh()
                if ($process.HasExited) {
                    throw "Windows app exited during startup: $($process.ExitCode). $(Get-Content $smokeStderr -Raw)"
                }
            } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
            if ($process.MainWindowHandle -eq 0 -or $process.MainWindowTitle -ne 'ESP-INK') {
                throw 'The packaged Windows app did not create its ESP-INK window.'
            }
            Start-Sleep -Seconds 2
            $process.Refresh()
            if ($process.HasExited) { throw 'Windows app exited immediately after creating its window.' }
            $smoke = 'window_created_and_process_alive'
        } finally {
            if (-not $process.HasExited) {
                [void]$process.CloseMainWindow()
                if (-not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
            }
            $process.Dispose()
            foreach ($log in @($smokeStdout, $smokeStderr)) {
                if (Test-Path $log) { Copy-Item $log -Destination $OutputDir -Force }
            }
        }
    }

    Move-Item -LiteralPath $temporaryZip -Destination $archivePath -Force:$Force
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumPath -Value "$archiveHash  $packageName.zip" -Encoding ascii
    $report['startup_smoke'] = $smoke
    $report['startup_path_test'] = 'ZIP extraction under a Unicode directory containing a space'
    $report['archive_sha256'] = $archiveHash
    $report['archive_file_count'] = $hashes.Count + 1
    Set-Content -LiteralPath $reportPath -Value ($report | ConvertTo-Json -Depth 5) -Encoding utf8NoBOM
    Write-Host "Packaged $archivePath ($($hashes.Count + 1) files)"
    Write-Host "SHA256 $archiveHash"
    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "artifact_name=$packageName"
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "zip_path=$archivePath"
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @"
ESP-INK **$version** / Windows x64 Release

- ZIP: $packageName.zip
- SHA256: ``$archiveHash``
- Files: $($hashes.Count + 1); PE32+ AMD64 and embedded app version checked.
- Startup smoke: $smoke. Hardware/BLE is not covered by this run.
"@
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
