# BagSpot

A high-performance MoonLoader script for **GTA: San Andreas Multiplayer (SA-MP)** — save, manage, and teleport to coordinates with integrated **Moneybag Hunting** automation and radar.

---

## Features

### Position Management
* **Instant Teleportation:** Move to saved locations instantly (on-foot or in-vehicle).
* **Permanent Storage:** All data is saved in `config/SavedPositions.json`.
* **Smart Search:** Search through saved locations by name.
* **Route System:** Create and execute sequential teleport routes.
* **Export/Import:** Share your positions or back them up via JSON.
* **Advanced UI:** Responsive interface built with `mimgui`.

### Moneybag Hunt (Automated)
* **Moneybag ESP:** Highlight nearby pickups (model 1550) with color-coded lines.
* **Chat Hint Detection:** Automatically detects location hints in chat (e.g., `"Hint: Grove Street"`).
* **ESP Focus Mode:** Automatically locks your ESP on the detected location to reduce clutter.
* **Auto-Teleport:** Automatically teleports you to detected moneybags (with a countdown and cooldown).
* **Mini-Radar:** Circular, rotating radar in the corner showing moneybag positions.
* **Proximity Pulse:** Visual and audio alerts when a moneybag is very close.
* **Sound Alerts:** Beeps for hint detection, spawns, and teleports.
* **Goldpot Database:** Matches hints against a known goldpot database; unknown hints are stored in a NEW tab for later saving.

---

## Installation

1. Ensure you have MoonLoader installed.
2. Download the script files.
3. Place `BagSpot.lua` into your `moonloader/` folder.
4. Place any required libraries in your `moonloader/lib/` folder.
5. Launch the game!

---

## Usage

### Hotkeys
| Key | Action |
| :--- | :--- |
| **F10** | Toggle the Main Menu |
| **F9** | Toggle standard ESP (all saved positions) |

### Chat Commands
| Command | Description |
| :--- | :--- |
| `/spos [name]` | Save current position with an optional name |
| `/lpos [name]` | Teleport to a position by name or index |
| `/poslist` | Display all saved positions in the chat |
| `/uc` | Update coordinates of the last known hint position |
| `/autotp` | Toggle automated moneybag teleportation |
| `/clearfocus` | Manually clear the active ESP focus |

---

## Data Management

### Exporting
Clicking **EXPORT Positions** generates a file at:
`MoonLoader/config/SavedPositions_Export.txt`

### Importing
1. Open the Import window in the menu.
2. Paste the JSON array.
3. Click **Import Data**.
*Note: Importing replaces your current list. Always export a backup first!*

---

## Companion Script: Auto Math Detector

`automath.lua` is bundled in this repo. It automatically detects "Math: Solve X+Y" prompts in chat, computes the answer, and submits it with a random 8-13s delay and a live countdown on screen.

### Installation
Place `automath.lua` in your `moonloader/` folder alongside `BagSpot.lua`.

### Configuration
Open `automath.lua` and change `ANSWER_CMD` if your server uses a different command (default: `/ans`).

---

## Dependencies

Both scripts require the following libraries:
- `mimgui`
- `vkeys`
- `encoding`
- `ffi`
- `samp.events`

---

## Author

**Developed by BOJO Dev**
*Version: 4.0*

---

*Disclaimer: Use teleportation features responsibly. Some servers may have anti-cheat systems that detect coordinate warping.*
