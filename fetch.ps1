# fetch.ps1 -- download, VERIFY, and extract the pinned corvid FFI release
# for this host (Windows), then normalize the artifacts into deps\current
# for the zig build. macOS/Linux: fetch.sh.
#
# Binding rules (docs/PLAN.md):
#   - the engine pin is EXACT and lives in ONE variable: $CorvidVersion;
#   - artifacts come only from the tag's GitHub release and are sha256-
#     verified against the release's checksums.txt before extraction;
#   - deps/ is gitignored -- no vendored binaries, ever;
#   - the release's golden/ fixtures must be byte-identical to the vendored
#     golden/ in this repo -- a divergence is an artifact finding, not a
#     patch-here.
#
# Deterministic and idempotent: re-running with the same pin is a no-op;
# stale engine versions are always discarded.

$ErrorActionPreference = "Stop"

# THE pin. Bump here and nowhere else.
$CorvidVersion = "v0.3.0"
$Repo          = "corvid-db/corvid"

$Root = $PSScriptRoot
$Deps = Join-Path $Root "deps"
$Dl   = Join-Path $Deps "dl"

# ---- host platform -> release target ------------------------------------
# The release publishes x86_64 Windows artifacts only; ARM64 Windows has no
# artifact to pin, so it is an explicit error rather than a silent mismatch.
$Target = switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "x86_64-pc-windows-msvc"; break }
    default { Write-Error "fetch.ps1: unsupported host $($env:PROCESSOR_ARCHITECTURE) (the pinned release publishes x86_64 Windows artifacts only)" }
}

$Archive   = "corvid-ffi-$CorvidVersion-$Target.zip"
$BaseUrl   = "https://github.com/$Repo/releases/download/$CorvidVersion"
$Extracted = Join-Path $Deps "corvid-ffi-$CorvidVersion-$Target"

Write-Host "fetch: corvid $CorvidVersion for $Target"

New-Item -ItemType Directory -Force -Path $Dl  | Out-Null
New-Item -ItemType Directory -Force -Path $Deps | Out-Null

# ---- stale-version cleanup: always discard anything not the current pin --
Get-ChildItem -Path $Deps -Directory -Filter "corvid-ffi-*" |
    Where-Object { $_.Name -ne "corvid-ffi-$CorvidVersion-$Target" } |
    Remove-Item -Recurse -Force

# ---- download checksums + (if needed) the archive ------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile (Join-Path $Dl "checksums.txt")

if (Test-Path $Extracted) {
    Write-Host "fetch: $Extracted already present -- verifying stamp only"
} else {
    $ArchivePath = Join-Path $Dl $Archive
    Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile $ArchivePath

    # ---- verify: sha256 against the release's checksums.txt -------------
    $Expected = (Select-String -Path (Join-Path $Dl "checksums.txt") `
        -Pattern "^([0-9a-f]{64})\s+$([regex]::Escape($Archive))\s*$").Matches[0].Groups[1].Value
    if (-not $Expected) {
        Write-Error "fetch: $Archive is not listed in the release checksums.txt"
    }
    $Actual = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLower()
    if ($Actual -ne $Expected) {
        Write-Error "fetch: sha256 MISMATCH for ${Archive}: expected $Expected, actual $Actual"
    }
    Write-Host "fetch: sha256 ok ($Actual)"

    # ---- extract ----------------------------------------------------------
    Expand-Archive -Path $ArchivePath -DestinationPath $Deps
}

if (-not (Test-Path (Join-Path $Extracted "corvid.h")) -or
    -not (Test-Path (Join-Path $Extracted "corvid.dll")) -or
    -not (Test-Path (Join-Path $Extracted "corvid.dll.lib"))) {
    Write-Error "fetch: $Extracted is missing corvid.h / corvid.dll / corvid.dll.lib -- bad archive?"
}
$golden = Get-ChildItem -Path (Join-Path $Extracted "golden") -Filter "*.txt"
if (-not $golden) {
    Write-Error "fetch: $Extracted/golden holds no fixtures"
}

# ---- the vendored golden fixtures must match the release's byte for byte --
foreach ($f in Get-ChildItem -Path (Join-Path $Root "golden") -Filter "*.txt") {
    $rel = Join-Path $Extracted "golden\$($f.Name)"
    if ((Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash -ne
        (Get-FileHash -Algorithm SHA256 -Path $rel).Hash) {
        Write-Error "fetch: vendored golden/$($f.Name) differs from the release's copy -- artifact finding, not a patch-here"
    }
}

# ---- normalize into deps\current (what build.zig points at) ---------------
# A stable directory name keeps the build platform-independent. The MSVC
# import library keeps its corvid.dll.lib name (lld-link consumes it on the
# windows-msvc ABI); the libcorvid.dll.a copy gives the mingw (windows-gnu)
# flavor of the zig toolchain a name its ld searches for `-lcorvid`.
# corvid.dll must additionally be on PATH (or beside the binary) at runtime
# for the loader.
$Cur = Join-Path $Deps "current"
if (Test-Path $Cur) { Remove-Item -Recurse -Force $Cur }
New-Item -ItemType Directory -Force -Path $Cur | Out-Null
Copy-Item (Join-Path $Extracted "corvid.h")     $Cur
Copy-Item (Join-Path $Extracted "corvid.dll")   $Cur
Copy-Item (Join-Path $Extracted "corvid.dll.lib") (Join-Path $Cur "corvid.dll.lib")
Copy-Item (Join-Path $Extracted "corvid.dll.lib") (Join-Path $Cur "libcorvid.dll.a")

# ---- the stamp (single source of truth for the version) ------------------
Set-Content -Path (Join-Path $Deps "version.txt") -Value $CorvidVersion -NoNewline
Write-Host "fetch: deps\current ready (corvid.h, corvid.dll, import lib) -- pin $CorvidVersion"
Write-Host "fetch: note -- corvid.dll must be on PATH (or beside your binary) at runtime"
