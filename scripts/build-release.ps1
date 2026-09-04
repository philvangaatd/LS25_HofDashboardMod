param(
    [string]$ArtifactDirectory = "dist",
    [string]$PackageName = "FS25_HofDashboard.zip"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$artifactRoot = if ([System.IO.Path]::IsPathRooted($ArtifactDirectory)) {
    $ArtifactDirectory
} else {
    Join-Path $repositoryRoot $ArtifactDirectory
}
$packagePath = Join-Path $artifactRoot $PackageName
$repositoryRootPrefix = $repositoryRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
if (Test-Path -LiteralPath $packagePath) {
    Remove-Item -LiteralPath $packagePath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($packagePath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $files = @(
        Join-Path $repositoryRoot "modDesc.xml"
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "scripts") -Filter "*.lua" -File | Sort-Object Name | Select-Object -ExpandProperty FullName
    )

    foreach ($file in $files) {
        $absoluteFile = (Resolve-Path -LiteralPath $file).Path
        if (-not $absoluteFile.StartsWith($repositoryRootPrefix)) {
            throw "File is outside repository root: $absoluteFile"
        }
        $relativePath = $absoluteFile.Substring($repositoryRootPrefix.Length).Replace("\", "/")
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $file,
            $relativePath,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
} finally {
    $zip.Dispose()
}

$requiredEntries = @(
    "modDesc.xml",
    "scripts/Version.lua",
    "scripts/HofDashboard.lua",
    "scripts/FieldsCollector.lua",
    "scripts/VehiclesCollector.lua",
    "scripts/AnimalsCollector.lua",
    "scripts/ProductionsCollector.lua",
    "scripts/StorageCollector.lua",
    "scripts/ContractsCollector.lua",
    "scripts/MarketCollector.lua",
    "scripts/PlaceableRegistryAdapter.lua"
)

$actualEntries = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
try {
    $entryNames = @($actualEntries.Entries | ForEach-Object { $_.FullName })
    foreach ($requiredEntry in $requiredEntries) {
        if ($entryNames -notcontains $requiredEntry) {
            throw "Required package entry is missing: $requiredEntry"
        }
    }
    if ($entryNames | Where-Object { $_ -like "*\*" }) {
        throw "Package contains backslash paths. GIANTS Engine expects slash-separated paths."
    }
} finally {
    $actualEntries.Dispose()
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagePath).Hash.ToLowerInvariant()
Write-Host "Mod package: $packagePath"
Write-Host "SHA-256: $hash"
