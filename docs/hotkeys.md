# jellyfin-web hotkeys: keyboard, controller, TV mode

Stock jellyfin-web bindings (verified against 10.11.x), plus the extra keys added by the
optional `jellyfin-menu.user.js`. Useful because a couch HTPC usually runs on a wireless
keyboard or a gamepad.

## Keyboard -- during video playback

| Key | Action |
|---|---|
| `Space`, `K` | Play/pause |
| `Left`, `J` | Skip back |
| `Right`, `L` | Skip forward |
| `Up` / `Down` | Volume up / down |
| `M` | Toggle mute |
| `F` | Toggle fullscreen |
| `Enter` | Show OSD |
| `Escape` | Hide OSD |
| `0`-`9` | Seek to 0%-90% |
| `Home` / `End` | Seek to start / end |
| `PageUp` / `PageDown` | Next / previous chapter |
| `Shift+N` / `Shift+P` | Next / previous episode |
| `>` / `<` | Increase / decrease playback speed |

Keys with `Ctrl`/`Alt`/`Win` held are ignored. Skip-back/forward lengths are configurable
in User > Playback.

## Keyboard -- added by `optional/jellyfin-menu.user.js`

mpv-style keys, active during playback only (ignored while a menu/dialog or input field
is open):

| Key | Action |
|---|---|
| `A` | Cycle audio track (wraps; shows a toast with the track name) |
| `S` | Cycle subtitle track (wraps, includes Off) |
| `I` | Toggle the playback stats overlay |
| `Q` | Close the player, back to the library (stops playback) |

## Keyboard -- outside playback

- Library views: just type -- letters/digits jump to the first item with that prefix.
- Hardware media keys (Play/Pause/Next/Prev) work OS-wide via the browser's MediaSession.

## Controller / gamepad

Two settings, both in the user settings of jellyfin-web (per-URL, like everything else):

1. **Display > Layout -> TV**: switches to the 10-foot layout with focus-based navigation
   (this is what makes D-pad browsing work at all).
2. **Controls > Gamepad -> on**: enables the controller input mapping (off by default).

With both set, the controller maps to synthesized key presses:

| Control | Action |
|---|---|
| D-pad / left stick | Move focus (arrow keys) |
| `A` | Select / play-pause during playback (Enter) |
| `B` | Back (Escape) |
| D-pad left/right during playback | Skip back / forward |

`X`, `Y`, `LB`, `RB`, triggers and the right stick are not used by jellyfin-web -- the
optional `jellyfin-menu.user.js` maps them:

| Control | Action |
|---|---|
| `X` | Play the focused card |
| `Y` | Context menu of the focused card; during playback: stats overlay |
| `LB` / `RB` | Skip back / forward by your configured skip lengths (OSD-less) |
| Right stick left/right | Fine -5s / +5s nudge (repeats while held) |

## TV mode notes

In TV layout, `Escape`/`B` is back, `Enter`/`A` is select, and the pointer auto-hides.
The layout is a user setting, so set it on the HTPC's URL only -- your desktop browser
stays on the desktop layout.
