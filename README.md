MEDIABAR - mini player inside the taskbar (Windows 11) vibecoded with Claude Fable 5
==============================================================

What it does:
Shows the current track (Times New Roman) and three buttons
(previous, play/pause, next) INSIDE the taskbar, with a fully
invisible background: the bar photographs the strip of taskbar
beneath it and uses it as its own background, so only the text
and the icons are visible. It never covers application windows,
and when something runs full screen (movie, game, F11) it hides
automatically, just like the taskbar, and comes back on its own.
The width adapts to the title length; the buttons always stay in
the same spot (the bar grows to the left).

The title always follows what is actually AUDIBLE: a playing
Windows media session first (Spotify, browsers...), then a playing
Winamp-style player, then a paused session. The three buttons
control exactly the player being shown - for Winamp-style players
they use that player's own commands (Winamp's classic API,
foobar2000/MusicBee/AIMP command-line switches, the standard media
message for the rest), so prev/play/next work on them too.
A flicker safety net keeps the title steady: sources that are
audibly playing take over instantly, while a silent source may
replace the display only after ~4 seconds of being the steady
candidate - so brief gaps between tracks or the moment right
after a pause no longer make the title jump around. Pressing
prev/next on the bar also locks the shown source for a few
seconds, so the brief transition (while the track changes) cannot
let another playing app hijack the title and the button target.

How to start:
1. Extract the folder anywhere (e.g. Documents).
2. Double-click "Start MediaBar.vbs" - it starts completely
   silently, with no console window.
   If SmartScreen warns you: "More info" -> "Run anyway".

Usage:
- The bar appears on the right side of the taskbar, near the clock.
- When 2+ players run at the same time, a small ARROW appears on
  the left of the title. Click it to open a panel listing every
  active player, each with its own pause/play button, so you can
  silence one without touching the others. The panel closes by
  itself when you move the mouse away. Winamp-style players are
  listed too and are paused by talking straight to their window
  (Winamp's classic command, foobar2000/MusicBee/AIMP command-line
  switches, standard media message for the rest); their play state
  cannot be read, so their button is a blind toggle - except
  Winamp: its own [Paused]/[Stopped] title marker is read every
  cycle and always wins over the audio session (which Winamp keeps
  open even while paused), so its state is accurate. Winamp is
  detected even when minimized to the tray.
- If Spotify is missing from the panel, enable "Show desktop
  overlay when using media keys" in Spotify's settings - that
  toggle IS Spotify's Windows media integration.
- Move it left/right: hold the title and drag. While dragging a
  plain box is shown; on release it melts back into the taskbar.
- Mouse wheel over the bar: adjusts the volume ONLY for MEDIA apps
  that are actively playing right now (players and browsers, plus
  the app shown in the title) - voice/chat apps like Discord, and
  games, are never touched. The allowed list is at the top of the
  wheel section in MediaBar.ps1 if you want to extend it. Windows
  will not show its volume popup, since the master volume is
  untouched (changes are visible in the Volume Mixer). When no
  media app is playing, the wheel falls back to the system master
  volume. Uses the default Windows "scroll inactive windows"
  setting.
- Right-click the title: move back next to the clock, start with
  Windows, media detection status, CLOSE (there is no X button;
  close it from here).
- When nothing is playing, the title area stays blank and the bar
  shrinks to a small pill.
- If you change the taskbar theme/color and the background no
  longer matches, right-click -> "Move back next to the clock"
  refreshes it.

Resource usage:
- The background capture is a single small "photo" (a few tens of
  KB), taken only at startup, on move, on reposition and when
  returning from full screen. Nothing is recorded continuously.
- The fast anti-burial re-pin runs on a native background thread
  (zero script-engine cost), the audio connection is reused
  between queries instead of being rebuilt, and on machines with
  no Winamp-style players the audio system is not polled at all.
- The track is checked every 2 seconds, players without Windows
  integration every 5 seconds (targeted, only the one found), the
  process runs at low priority and trims its unused memory every
  5 minutes.
- Idle CPU usage is practically zero. The memory shown in Task
  Manager (~50-80 MB) is the fixed cost of the PowerShell
  platform, not of the bar itself.

Files used (nothing is installed):
- position: %APPDATA%\MediaBar.cfg
- errors (only if any occur): %APPDATA%\MediaBar.log
- optionally, the autostart shortcut (only if you enable it).

Note: if you had autostart enabled from an older version, untick
and re-tick it in the menu so the shortcut points to the new
"Start MediaBar.vbs" launcher.
