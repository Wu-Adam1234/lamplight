# Changelog

## 1.0.0 (2026-10-31)

First release, for macOS and Windows.

- Menu bar lantern: lit when on, dark when off, with a short flame animation (skipped when Reduce Motion is on).
- Left-click toggles. Right-click (or Control/Option-click) opens the menu.
- A click runs until you click again by default; Turn On For offers 15 and 30 minutes, 1, 2, 4 and 8 hours.
- Turn On Lasts changes what a plain click does.
- Keep awake with the lid closed, after a one-time password prompt that installs a single,
  narrow sudoers rule. Removable from the menu.
- Keep Screen On toggle.
- Turns off on low battery (10% by default; 5, 20, 30% or never).
- Time left in the menu bar (optional).
- Open at Login.
- Normal sleep is restored on turn off, timer end, battery cutoff, quit and SIGTERM. A small watchdog
  restores it within seconds after a crash or force-quit, and the next launch checks again.

### Windows

- System tray app with the same lantern, clicks, timers and settings.
- Lid-closed mode switches the power plan's lid action to "Do nothing" while on and restores your
  own setting afterwards, with a watchdog for crashes. No admin rights needed on most PCs.
- Start with Windows; self-contained exe for x64 and ARM64.
