<#
setup.ps1 -- guided prerequisite installer for dovi-jellyfin.

Run it from the cloned/unzipped repo folder; the launcher and gate paths are all
relative to the repo, nothing gets copied around.

Interactive: checks the Dolby Vision hard requirement FIRST (so you never buy the paid
HEVC extension for nothing), then installs the free Store media extensions via winget and
walks through the rest. Nothing is purchased automatically.

Run from a normal PowerShell (5.1 or 7). The MV2 policy pin and the optional URL
reservation need an elevated shell; everything else works unelevated.
#>
$ErrorActionPreference = 'Continue'

function Ask([string]$q) {
  while ($true) {
    $a = (Read-Host "$q [y/n]").Trim().ToLower()
    if ($a -eq 'y') { return $true }
    if ($a -eq 'n') { return $false }
  }
}
function StoreInstall([string]$id, [string]$name) {
  Write-Host "  installing $name ..."
  $global:LASTEXITCODE = 0
  $ok = $false
  try { winget install --id $id --source msstore --accept-source-agreements --accept-package-agreements; $ok = ($LASTEXITCODE -eq 0) } catch {}
  if (-not $ok) { Write-Host "  -> failed/skipped ($name). Store page: ms-windows-store://pdp/?ProductId=$id" -ForegroundColor Yellow }
}
# resolve pwsh even when a just-finished winget install isn't on this process's PATH yet
function Find-Pwsh {
  $c = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $p = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
  if (Test-Path $p) { return $p }
  return $null
}
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host "winget not found -- install 'App Installer' from the Microsoft Store first, then re-run." -ForegroundColor Yellow
  exit 1
}

Write-Host ""
Write-Host "=== dovi-jellyfin setup ===" -ForegroundColor Cyan
Write-Host "Unofficial community setup -- not affiliated with Jellyfin, Dolby, or Microsoft."
Write-Host ""

# ---- STEP 0: the hard gate -----------------------------------------------------------
Write-Host "STEP 0: Dolby Vision certification check (DO NOT SKIP)" -ForegroundColor Yellow
Write-Host @"

  Opening Settings > System > Display > Advanced display.
  Look for the line:   HDR certification: Dolby Vision

  If 'Dolby Vision' is NOT listed there, Windows will never engage the DV decoder and
  NOTHING in this repo can help until it does. Fix the EDID first (CRU + the Dolby VSVDB
  edit): https://github.com/balu100/dolby-vision-for-windows
  In particular do NOT buy the paid HEVC extension yet.
"@
Start-Process 'ms-settings:display-advanced'
if (-not (Ask "Does 'HDR certification' list 'Dolby Vision'?")) {
  Write-Host ""
  Write-Host "Stop here. Do the EDID/VSVDB edit first, reboot, re-check that settings page," -ForegroundColor Yellow
  Write-Host "then re-run this script. Guide: https://github.com/balu100/dolby-vision-for-windows"
  exit 1
}

# ---- STEP 1: free Store media extensions ---------------------------------------------
Write-Host ""
Write-Host "STEP 1: free Store media extensions (via winget)" -ForegroundColor Yellow
if (Ask "  Install the free media extensions (Dolby Vision, Dolby Access, AV1, VP9, MPEG-2, Web Media)?") {
  StoreInstall 9PLTG1LWPHLF 'Dolby Vision Extensions'
  StoreInstall 9N0866FS04W8 'Dolby Access'          # set the DV color mode here + confirms the DV extension works
  StoreInstall 9MVZQVXJBQ9V 'AV1 Video Extension'
  StoreInstall 9N4D0MSMP0PT 'VP9 Video Extensions'
  StoreInstall 9N95Q1ZZPMH4 'MPEG-2 Video Extension'
  StoreInstall 9N5TDP8VCMHS 'Web Media Extensions'  # OGG container + Vorbis/Theora for Edge
}

# ---- STEP 2: HEVC --------------------------------------------------------------------
Write-Host ""
Write-Host "STEP 2: HEVC Video Extensions (required for DV decode)" -ForegroundColor Yellow
Write-Host "  Trying the free 'from Device Manufacturer' package first (delisted from Store"
Write-Host "  browsing, but the package itself may still install) -- good for TESTING the"
Write-Host "  whole DV chain before spending money."
if (Ask "  Try the free HEVC package?") {
  StoreInstall 9N4WGH0Z6VHQ 'HEVC Video Extensions from Device Manufacturer (free)'
}
Write-Host "  HINT: once everything works, switch to the PAID package (~1 USD/EUR) for your"
Write-Host "  final setup -- the free one is delisted and frozen, and it is unclear whether"
Write-Host "  both ship the same binaries; the paid one is the maintained/official codec."
if (Ask "  Open the PAID HEVC Store page?") { Start-Process 'ms-windows-store://pdp/?ProductId=9NMZLZ57R3T7' }

# ---- STEP 3: PowerShell 7 + DisplayConfig (only needed for the optional HDR gate) -----
Write-Host ""
Write-Host "STEP 3: PowerShell 7 + DisplayConfig module (for optional/jf-hdr-gate.ps1)" -ForegroundColor Yellow
if (Find-Pwsh) {
  Write-Host "  pwsh found -> OK"
} elseif (Ask "  pwsh not found. Install via winget now?") {
  winget install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements
}
$pwsh = Find-Pwsh
if (-not $pwsh) {
  Write-Host "  pwsh still not found (new install may need a fresh shell) -> skipping the module step; re-run setup later." -ForegroundColor Yellow
} else {
  $hasModule = (& $pwsh -NoProfile -Command "[bool](Get-Module -ListAvailable DisplayConfig)") -eq 'True'
  if ($hasModule) {
    Write-Host "  DisplayConfig module found -> OK"
  } elseif (Ask "  Install the DisplayConfig module (PSGallery, CurrentUser scope)?") {
    & $pwsh -NoProfile -Command "Install-Module DisplayConfig -Scope CurrentUser -Force"
  }
}

# ---- STEP 4: ViolentMonkey + MV2 -----------------------------------------------------
Write-Host ""
Write-Host "STEP 4: ViolentMonkey (userscript manager)" -ForegroundColor Yellow
if (Ask "  Open the ViolentMonkey page in the Edge Add-ons store?") {
  Start-Process 'https://microsoftedge.microsoft.com/addons/detail/violentmonkey/eeagobfjdenkkddmbclomhiblgggliao'
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "  ViolentMonkey is a Manifest V2 extension. The policy below keeps MV2 enabled for"
Write-Host "  now (a compatibility measure, not a permanent pin -- Tampermonkey MV3 is the"
Write-Host "  fallback if Edge ever drops MV2; the userscript ports as-is)."
if ($isAdmin) {
  if (Ask "  Set the Edge MV2 policy now?") {
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v ExtensionManifestV2Availability /t REG_DWORD /d 2 /f
  }
} else {
  Write-Host "  Not elevated -> run this later in an ADMIN shell:" -ForegroundColor Yellow
  Write-Host '    reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v ExtensionManifestV2Availability /t REG_DWORD /d 2 /f'
}

# ---- STEP 5: URL reservation for the gate (optional) ----------------------------------
Write-Host ""
Write-Host "STEP 5: HTTP URL reservation for the optional gate service" -ForegroundColor Yellow
Write-Host "  Windows may refuse to let a non-admin process listen on http://127.0.0.1:17999/."
if ($isAdmin) {
  if (Ask "  Add the URL reservation for your user now?") {
    netsh http add urlacl url=http://127.0.0.1:17999/ user="$env:USERDOMAIN\$env:USERNAME"
  }
} else {
  Write-Host "  Not elevated -> if the gate later logs a listener error, run in an ADMIN shell:" -ForegroundColor Yellow
  Write-Host "    netsh http add urlacl url=http://127.0.0.1:17999/ user=`"$env:USERDOMAIN\$env:USERNAME`""
}

# ---- remaining manual steps ----------------------------------------------------------
Write-Host ""
Write-Host "=== Done. Manual steps left (see README): ===" -ForegroundColor Cyan
Write-Host @"
  - Import required/jellyfin-dv.user.js into ViolentMonkey; check its @match covers your Jellyfin URL.
  - Edit required/jellyfin-edge-dv.cmd: the Jellyfin URL at the bottom.
  - Edge settings: disable 'Startup boost' and background extensions/apps.
  - jellyfin-web settings (on the SAME URL you will use!): see the README Jellyfin-settings
    table (fMP4-HLS on, DTS/TrueHD off, PGS rendering on; server: throttle/delete-segments off).
  - Set the desktop to 10-bit RGB Full range (GPU control panel).
  - Launch sessions via required/jellyfin-edge-dv.cmd; if you use the gate, confirm
    http://127.0.0.1:17999/health answers.
"@
