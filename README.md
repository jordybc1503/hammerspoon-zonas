# hammerspoon-zonas

FancyZones-style window zones for macOS, built on [Hammerspoon](https://www.hammerspoon.org/).
Made for a 49" super-ultrawide screen (Dell U4924DW, 5120 × 1440), with a separate layout for
each screen.

## What it does

- **Zones from the keyboard:** `⌃⌥` + a zone's key moves the focused window into that zone.
- **Zones with the mouse:** drag a window while you hold **Shift**, then drop it on a zone.
  Also hold **Ctrl** to span several zones.
- **Visual editor** (▦ menu → *Edit zones and shortcuts…*): split zones into columns or rows,
  drag the lines to resize, add floating zones that sit on top, and set each zone's key.
- **One layout per screen:** the ultrawide and the laptop use different layouts. A screen with
  no choice gets the default layout if it is ultrawide, and *Halves* if it is not.
- **Configurable shortcuts**, a gap between zones, and a Spanish or English interface (or the
  system language).
- **Translator:** select a word in any app and press `⌘⌥T`. It uses the Oxford Spanish-English
  dictionary that comes with macOS, with no network.

## Default shortcuts

On a Windows keyboard, `⌘` is the Windows key and `⌥` is Alt.

| Shortcut | What it does |
|---|---|
| `⌃⌥←` / `⌃⌥→` | Left / right free side |
| `⌃⌥1` `⌃⌥2` `⌃⌥3` | The three center zones (together, the width of a 34" monitor) |
| `⌃⌥4` | Floating reading zone: a 16:9 24" monitor, on top of the others |
| `⌃⌥↩` | Full screen |
| Shift + drag | Drop the window on a zone (+ Ctrl: span zones) |
| `⌘⌥T` | Translate the selected word |

## Install

1. Install Hammerspoon: `brew install --cask hammerspoon`
2. Clone this repo into `~/.hammerspoon`:
   `git clone https://github.com/jordybc1503/hammerspoon-zonas.git ~/.hammerspoon`
3. Build the translator: `swiftc -O ~/.hammerspoon/bin/dict.swift -o ~/.hammerspoon/bin/dict`
4. Open Hammerspoon and give it **Accessibility** access (System Settings → Privacy & Security →
   Accessibility).

The **▦** icon appears in the menu bar. It lists the shortcuts, the layout of each screen and
the editor.

## Files

| File | What it is |
|---|---|
| `init.lua` | The translator, and it starts the zones |
| `zonas.lua` | Zones, templates, shortcuts, dragging, the ▦ menu, and the Spanish and English texts |
| `zonas.html` | The editor, opened from the ▦ menu |
| `zonas.json` | What you save in the editor. Without it, the defaults apply |
| `bin/dict.swift` | The program that reads the macOS dictionary |

## License

MIT
