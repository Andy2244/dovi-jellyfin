<#
jf-hdr-gate.ps1 -- resident local display gate for the Edge DV client. Runs in the
interactive desktop session (DisplayConfig fails in SSH session 0). The userscript POSTs
the item's video range + fps before playback; this matches the desktop HDR + refresh
(only the dimensions that differ), then acks after the TV settles so DV/HDR + the right
cadence engage on the first frame (no mid-play stutter).

Desktop stays 4K; only HDR + refresh change. Refresh uses the STAGED apply
(Get-DisplayConfig -> Set-DisplayRefreshRate -DisplayConfig -> Use-DisplayConfig), never
the partial set (Intel stuck-mixed history), and only to a rate the driver advertises at
4K (the module won't validate -- a bad rate blanks the TV silently).

  GET  /health                            -> {ok:true, display:N}
  POST /nudge                             -> 1px cursor nudge (launcher fires it after Edge starts)
  POST /gate?hdr=0|1&range=<VRT>&fps=<n>  -> match HDR + refresh; {status, changed, hdr, rate}
  POST /default                           -> reset to the known-good baseline (-DefaultHdr + -DefaultHz)
  POST /quit                              -> shut the service down (TV-off ritual; the
                                             Edge launcher starts it again on next session)
#>
[CmdletBinding()]
param(
  [int]$Port = 17999,
  [uint32]$DisplayId = 1,        # display to control (single-display HTPC = 1)
  [int]$SettleMs = 3000,         # after the flip, wait this before acking so the TV re-syncs before Edge builds the decode chain; raise if your TV blanks longer
  [double]$DefaultHz = 23.976,   # idle/browse refresh rate; /default + startup reset here
  [switch]$DefaultHdr,           # known-good baseline includes HDR ON (default: SDR) -- for HDR-always-on desktops
  [switch]$RefreshOnly,          # never touch HDR, only match the refresh rate (you keep HDR on and accept SDR-under-HDR)
  # 4K rates your display reaches at 10-bit (HDMI 2.0 caps 4K RGB 10-bit at 30Hz, hence film rates only);
  # content fps maps to the nearest entry, and every switch is still validated against the live driver mode list
  [double[]]$ReachableHz = @(23.976, 24.0, 25.0, 29.97, 30.0),
  # empty = accept POSTs from any local browser page. On a shared/non-dedicated PC set this to your
  # Jellyfin origin(s), e.g. @('http://localhost:8096'), so random websites can't poke the gate.
  [string[]]$AllowedOrigins = @(),
  [string]$LogPath = "$PSScriptRoot\jf-hdr-gate.log"
)

$ErrorActionPreference = 'Stop'

# Run this ONE file directly on the HTPC (no wrapper needed); minimize our own console on launch.
try {
  $Host.UI.RawUI.WindowTitle = 'jf-hdr-gate'
  Add-Type -Name Con -Namespace JfWin -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);'
  [JfWin.Con]::ShowWindow([JfWin.Con]::GetConsoleWindow(), 6) | Out-Null   # 6 = SW_MINIMIZE
} catch {}

Import-Module DisplayConfig -ErrorAction Stop

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace JfWin {
  public struct POINT { public int X; public int Y; }
  public class Cur {
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  }
}
'@

# EnumDisplaySettings -- the authority for "can the sink actually show this mode". The module
# accepts a bogus rate silently and Use-DisplayConfig would then blank the TV with no error, so
# every switch is gated on this live list (driver only advertises modes the EDID + bandwidth allow).
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class DU {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public ushort dmSpecVersion; public ushort dmDriverVersion; public ushort dmSize; public ushort dmDriverExtra;
    public uint dmFields; public int dmPositionX; public int dmPositionY; public uint dmDisplayOrientation; public uint dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public ushort dmLogPixels; public uint dmBitsPerPel; public uint dmPelsWidth; public uint dmPelsHeight;
    public uint dmDisplayFlags; public uint dmDisplayFrequency;
    public uint dmICMMethod; public uint dmICMIntent; public uint dmMediaType; public uint dmDitherType;
    public uint dmReserved1; public uint dmReserved2; public uint dmPanningWidth; public uint dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
}
'@

# Live set of int refresh rates the driver advertises at 4K for this device (23=23.976, 29=29.97, ...).
function Get-Available4kRates([string]$dev) {
  $set = @{}; $dm = New-Object DU+DEVMODE
  $dm.dmSize = [uint16]([Runtime.InteropServices.Marshal]::SizeOf([type]('DU+DEVMODE')))
  $i = 0
  while ([DU]::EnumDisplaySettings($dev, $i, [ref]$dm)) {
    if ($dm.dmPelsWidth -eq 3840 -and $dm.dmPelsHeight -eq 2160) { $set[[int]$dm.dmDisplayFrequency] = $true }
    $i++
  }
  return $set.Keys
}

function Log([string]$m) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 } catch {}
}

# content fps -> target refresh (nearest reachable within 0.5Hz), else $null = don't switch.
function Resolve-Refresh([double]$fps) {
  if ($fps -le 0) { return $null }
  $best = $null; $bestd = [double]::MaxValue
  foreach ($r in $ReachableHz) { $d = [math]::Abs($r - $fps); if ($d -lt $bestd) { $bestd = $d; $best = $r } }
  if ($bestd -le 0.5) { return $best }   # 23.81 -> 23.976 too; 50/60 -> null
  return $null
}

# Get-DisplayHDR (v6.0.0) returns HDRDisplayInfo with a bool .HDREnabled. Fail loud on an
# unexpected shape rather than guessing (a wrong "already on" read would skip a needed flip).
function Get-HdrOn([uint32]$id) {
  $o = Get-DisplayHDR -DisplayId $id
  if ($o.PSObject.Properties.Name -contains 'HDREnabled') { return [bool]$o.HDREnabled }
  Log ('Get-HdrOn: unexpected Get-DisplayHDR shape: ' + ($o | ConvertTo-Json -Compress))
  throw 'Get-DisplayHDR has no HDREnabled property'
}

function Get-CurRate([uint32]$id) { return [double](Get-DisplayInfo -DisplayId $id).Mode.RefreshRate }

# 1px cursor nudge: makes Edge re-apply cursor:none after a display change re-showed the OS
# cursor; stays under the web client's 10px move threshold so the OSD never wakes
function Invoke-CursorNudge {
  try {
    $p = New-Object JfWin.POINT
    if (-not [JfWin.Cur]::GetCursorPos([ref]$p)) { return }
    [JfWin.Cur]::SetCursorPos($p.X + 1, $p.Y) | Out-Null
    $q = New-Object JfWin.POINT
    if ([JfWin.Cur]::GetCursorPos([ref]$q) -and $q.X -eq $p.X -and $q.Y -eq $p.Y) {
      [JfWin.Cur]::SetCursorPos($p.X - 1, $p.Y) | Out-Null   # x+1 clamped at the screen edge -> go left
    }
    # let Edge receive the out-move before restoring, or Windows coalesces the pair to a net-zero no-op
    Start-Sleep -Milliseconds 75
    [JfWin.Cur]::SetCursorPos($p.X, $p.Y) | Out-Null
  } catch { Log "cursor nudge failed: $_" }
}

# Apply a refresh change via the staged full-config path. 0.01Hz tol keeps 23.976 vs 24.000 distinct.
# Guarded: skip if the driver doesn't advertise the mode (blanks the TV), and revert-on-fail.
function Set-Refresh([uint32]$id, [double]$hz) {
  $cur = Get-CurRate $id
  if ([math]::Abs($cur - $hz) -le 0.01) { Log ("refresh already {0:0.###} (cur={1:0.####}) -> no switch" -f $hz, $cur); return $false }
  $want = [int][math]::Floor($hz)
  $avail = @(Get-Available4kRates $script:GdiDev)
  if ($avail -notcontains $want) { Log ("refresh {0:0.###} (int $want) not in driver 4K list [$($avail -join ',')] -> SKIP" -f $hz); return $false }
  Log ("refresh switch (display {0}): {1:0.####} -> {2:0.###}" -f $id, $cur, $hz)
  $good = Get-DisplayConfig                         # snapshot to revert to if the apply lands badly
  $disturbed = $false                              # true once the panel is touched -> a settle is owed even on failure
  try {
    $cfg = Get-DisplayConfig
    Set-DisplayRefreshRate -DisplayId $id -RefreshRate $hz -DisplayConfig $cfg | Out-Null
    $disturbed = $true
    Use-DisplayConfig -DisplayConfig $cfg -AllowChanges | Out-Null
    $now = Get-CurRate $id
    if ([math]::Abs($now - $hz) -gt 0.1) { throw "post-apply rate $now != target $hz" }
    return $true
  } catch {
    Log "refresh apply failed ($_) -> reverting"
    try { Use-DisplayConfig -DisplayConfig $good -AllowChanges | Out-Null; $disturbed = $true } catch { Log "REVERT FAILED: $_" }
    return $disturbed
  }
}

# Combined desktop switch: refresh (topology) FIRST then HDR, no sleep between (lets the TV
# coalesce into one re-sync), then verify + a single settle. Returns status/changed/hdr/rate.
# $hz $null -> leave refresh alone. Nothing differs -> instant (the binge case: same fps+HDR).
function Set-DisplayState([uint32]$id, [bool]$hdrOn, $hz) {
  # Read HDR up front while the display is stable -- reading it during the post-refresh re-sync can throw.
  $curHdr = Get-HdrOn $id
  if ($RefreshOnly) { $hdrOn = $curHdr }   # refresh-only mode: HDR stays whatever it is
  $hdrNeedsFlip = ($curHdr -ne $hdrOn)
  $refreshChanged = $false
  if ($null -ne $hz) {
    try { $refreshChanged = [bool](Set-Refresh $id ([double]$hz)) } catch { Log "refresh set failed: $_" }
  }
  if ($hdrNeedsFlip) {
    Log "HDR flip (display $id): $curHdr -> $hdrOn"
    Set-DisplayHDR -DisplayId $id -EnableHDR:$hdrOn | Out-Null
  } else {
    Log "HDR already $hdrOn -> no flip"
  }
  if (-not $refreshChanged -and -not $hdrNeedsFlip) {
    $rate = try { Get-CurRate $id } catch { 0 }
    Log ("no display change -> instant (hdr=$hdrOn rate={0:0.###})" -f $rate)
    Invoke-CursorNudge   # staleness can predate this play (TV hot-plug, earlier /default) -> nudge here too
    return @{ changed = $false; hdr = $hdrOn; rate = $rate; status = 'safe' }
  }
  $ok = $false
  for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 100; try { if ((Get-HdrOn $id) -eq $hdrOn) { $ok = $true; break } } catch {} }
  Start-Sleep -Milliseconds $SettleMs    # hold the ack until the TV has re-synced, so the userscript's deferred PlaybackInfo (and Edge's decode chain) lands in the stable mode (v8.6 preflight)
  Invoke-CursorNudge
  $finalHdr = try { Get-HdrOn $id } catch { $hdrOn }
  $rate = try { Get-CurRate $id } catch { 0 }
  $enc = '?'; $bit = 0
  try { $ci = Get-DisplayColorInfo -DisplayId $id; $enc = "$($ci.ColorEncoding)"; $bit = [int]$ci.BitsPerColorChannel } catch {}
  $st = if ($ok -and $finalHdr -eq $hdrOn) { 'safe' } else { 'degraded' }
  Log ("switch done: hdr=$finalHdr rate={0:0.###} enc=$enc bit=$bit os-confirmed=$ok status=$st" -f $rate)
  if ($bit -and $bit -lt 10) { Log "WARN: bit-depth dropped to $bit (expected 10) -- check chroma/bandwidth" }
  # Edge DV path wants RGB; YCbCr mismatches the full-range DWM compositor -> wrong blacks. Observe-only (not code-settable; reset RGB Full in IGCC). $enc is the enum NAME ("RGB"), not "0".
  if ($enc -ne '?' -and $enc -ne 'RGB') { Log "WARN: color encoding=$enc (expected RGB for the Edge DV path) -- reset RGB Full in Intel Graphics Command Center" }
  return @{ changed = $true; hdr = $finalHdr; rate = $rate; enc = $enc; bit = $bit; status = $st }
}

function Set-Cors($ctx) {
  $origin = $ctx.Request.Headers['Origin']
  # never reflect an origin the allowlist rejects
  if ($AllowedOrigins.Count -and $origin -and $AllowedOrigins -notcontains $origin) { return }
  $ctx.Response.Headers['Access-Control-Allow-Origin'] = if ($origin) { $origin } else { '*' }
  $ctx.Response.Headers['Access-Control-Allow-Methods'] = 'GET,POST,OPTIONS'
  $ctx.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
}
function Write-Json($ctx, [int]$code, $obj) {
  Set-Cors $ctx
  $ctx.Response.StatusCode = $code
  $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
  $ctx.Response.ContentType = 'application/json'
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.OutputStream.Close()
}

# Single-instance guard: bind the port BEFORE any display change. A second copy (double-start)
# would otherwise run the SDR baseline -- flipping HDR off mid-playback -- then fail to bind.
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() }
catch { Log "port $Port already in use -- another jf-hdr-gate is running; exiting without touching the display"; exit }

try { $script:GdiDev = (Get-DisplayInfo -DisplayId $DisplayId).GdiDeviceName; Log "device=$script:GdiDev available-4K=[$(@(Get-Available4kRates $script:GdiDev) -join ',')]" } catch { $script:GdiDev = $null; Log "device enum failed (refresh switching will skip): $_" }
try { Log ('startup color: ' + (Get-DisplayColorInfo -DisplayId $DisplayId | ConvertTo-Json -Compress -Depth 3)) } catch { Log "color read failed: $_" }
try { Set-DisplayState $DisplayId ([bool]$DefaultHdr) $DefaultHz | Out-Null } catch { Log "startup baseline failed: $_" }   # crash-safe reset to the known-good baseline
Log "jf-hdr-gate listening on http://127.0.0.1:$Port/ (display $DisplayId, default ${DefaultHz}Hz)"

while ($listener.IsListening) {
  # poll instead of a bare blocking GetContext() so PowerShell gets a statement boundary every 200ms and Ctrl-C can stop it; still single-threaded = switches serialized
  try {
    $task = $listener.GetContextAsync()
    while (-not $task.Wait(200)) { }
    $ctx = $task.Result
  } catch { Log "accept failed: $_"; Start-Sleep -Milliseconds 500; continue }
  try {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath.ToLower()
    if ($req.HttpMethod -eq 'OPTIONS') { Set-Cors $ctx; $ctx.Response.StatusCode = 204; $ctx.Response.OutputStream.Close(); continue }
    # origin allowlist (opt-in): browser requests carry an Origin header; curl/local tools don't and stay allowed
    $reqOrigin = $req.Headers['Origin']
    if ($AllowedOrigins.Count -and $reqOrigin -and $AllowedOrigins -notcontains $reqOrigin) {
      Log "rejected origin: $reqOrigin $path"
      Write-Json $ctx 403 @{ error = 'origin not allowed' }
      continue
    }
    switch -regex ($path) {
      '^/health$'  { Write-Json $ctx 200 @{ ok = $true; display = [int]$DisplayId }; break }
      '^/nudge$'   {
        if ($req.HttpMethod -ne 'POST') { Write-Json $ctx 405 @{ error = 'POST only' }; break }
        # cursor-refresh for a fresh Edge window; the launcher fires this after starting Edge
        Invoke-CursorNudge
        Write-Json $ctx 200 @{ ok = $true }
        break
      }
      '^/default$' {
        if ($req.HttpMethod -ne 'POST') { Write-Json $ctx 405 @{ error = 'POST only' }; break }
        Write-Json $ctx 200 (Set-DisplayState $DisplayId ([bool]$DefaultHdr) $DefaultHz)
        break
      }
      '^/quit$'    {
        if ($req.HttpMethod -ne 'POST') { Write-Json $ctx 405 @{ error = 'POST only' }; break }
        Write-Json $ctx 200 @{ ok = $true; quitting = $true }
        Log 'quit requested -> shutting down'
        $listener.Stop()
        break
      }
      '^/gate$'    {
        if ($req.HttpMethod -ne 'POST') { Write-Json $ctx 405 @{ error = 'POST only' }; break }
        $h = $req.QueryString['hdr']
        if ($h -ne '0' -and $h -ne '1') { Write-Json $ctx 400 @{ error = 'hdr must be 0 or 1' }; break }
        $on = ($h -eq '1')
        $range = $req.QueryString['range']
        $fpsRaw = $req.QueryString['fps']
        $fps = 0.0
        if ($fpsRaw) { try { $fps = [double]::Parse($fpsRaw, [Globalization.CultureInfo]::InvariantCulture) } catch { $fps = 0.0 } }
        $hz = Resolve-Refresh $fps
        Log ("gate: range='$range' fps=$fpsRaw -> hdr=$on refresh=" + $(if ($null -ne $hz) { "{0:0.###}" -f $hz } else { 'skip' }))
        Write-Json $ctx 200 (Set-DisplayState $DisplayId $on $hz)
        break
      }
      default { Write-Json $ctx 404 @{ error = 'not found' } }
    }
  } catch {
    Log "request error: $_"
    try { Write-Json $ctx 500 @{ error = "$_" } } catch {}
  }
}
