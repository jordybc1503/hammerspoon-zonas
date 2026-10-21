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

## Claude Code pet

A pet runs to the terminal window whose Claude Code session **finished**, **has a question** or
**needs your permission**. It uses your [Codex](https://openai.com/codex) pet from `~/.codex/pets`
(it runs in, waves, jumps, droops and looks at your mouse), or a drawn creature if you have none.

- It only shows up when you are not already in that session's window.
- Click it to go to the window. In default permission mode, **Approve** and **Deny** answer the
  prompt from the pop-up; in auto mode it only points you to a real prompt.
- The ▦ menu has a block of its own for the pet: turn it on or off, its **Mode**, the editor
  **Open folders in** uses, and **Pet settings…**, the editor's **Pet** tab (the pet, the
  events, its size and how it moves).
- Drag it somewhere and the next pets on that screen come there instead of to their window.
- **Mode** › **Focus** keeps it still: it only moves when a new message comes.
- The bubble shows the session's folder, with a button that opens it in your code editor.

It has two halves: `mascota.lua` here draws the pet, and a Claude Code plugin tells it what
happens. Install the plugin once, at the prompt of a Claude Code session:

```
/plugin install mascota --marketplace jordybc1503/hammerspoon-zonas
```

Answer `y` to add the marketplace, then pick a scope (*user* makes it work in every project).

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
| `mascota.lua` | The Claude Code pet: draws it, moves it, answers approvals |
| `claude-plugin/mascota/` | The Claude Code plugin that tells the pet what happens |
| `.claude-plugin/marketplace.json` | Makes this repo a Claude Code marketplace for that plugin |

## License

MIT
