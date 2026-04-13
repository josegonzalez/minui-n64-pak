# N64 for TrimUI

A MinUI Emu Pak for N64, wrapping the standalone `mupen64plus` N64 emulator (version 2.6.0).

## Requirements

This pak is designed and tested on the following MinUI Platforms and devices:

- `tg5040`: Trimui Brick (formerly `tg3040`)

Use the correct platform for your device.

## Installation

1. Mount your MinUI SD card.
2. Download the latest release from Github. It will be named `N64.pak.zip`.
3. Copy the zip file to `/Emus/$PLATFORM/N64.pak.zip`.
4. Extract the zip in place, then delete the zip file.
5. Confirm that there is a `/Emus/$PLATFORM/N64.pak/launch.sh` file on your SD card.
6. Create a folder at `/Roms/Nintendo 64 (N64)` and place your roms in this directory.
7. Unmount your SD Card and insert it into your MinUI device.

## Usage

Browse to `Nintendo 64` and press `A` to play a game.

The following filetypes are supported:

- Native: `.n64`, `.v64`, `.z64`
- Extracted: `.zip`, `.7z`

Extraction happens prior to game loading using 7-zip and can cause delays in loading the game. To avoid this, extract the game on your SD card instead.

While playing:

### Quick menu

Press the **Menu** button to open the in-game quick menu.

| Action | Button |
|--------|--------|
| Open / close menu | Menu |
| Navigate | D-pad |
| Confirm | A |
| Back | B |

The quick menu has five options:

- **Continue** — close the menu and resume playing
- **Save** — save your progress to a slot (d-pad left/right to pick a slot, A to save)
- **Load** — load a previous save (same controls as Save)
- **Options** — video, audio, performance, input, and shortcut settings
- **Quit** — exit the game

### Save slots

There are 8 save slots per game. When Save or Load is highlighted, use **d-pad left/right** to cycle through slots — a preview screenshot appears on the right. Press **A** to save or load immediately.

### Power button

| Press | Action |
|-------|--------|
| Short press (< 1 second) | Sleep — screen off, audio muted, game state auto-saved |
| Long press (≥ 1 second) | Power off — exits the game cleanly |

After 2 minutes of sleep the device suspends to RAM to save battery. Press the power button to wake.

### Options

Inside Options you can adjust settings like video plugin, CPU speed, frame skip, and more. Changes take effect immediately where possible. To keep your changes across game launches, scroll to **Save Changes** at the bottom of the Options list:

- **Save for Console** — saves settings for all games
- **Save for Game** — saves settings for the current game only
- **Restore Defaults** — resets to default settings

The menu shows whether you're using default, console, or game-specific settings.

### Video plugins

Two video plugins are included:

- **Rice** (default) — faster, better performance on the Brick's hardware
- **GLideN64** — more accurate rendering, heavier on the GPU

Change the plugin in Options → Core → Video Plugin (requires restarting the game).

### Controls (Brick)

The Brick has no analog sticks, so the d-pad doubles as the N64 joystick by default. For games that use the N64 d-pad (like Kirby 64 or puzzle games), the emulator automatically switches to d-pad mode. You can also change this manually in Options → Input → Input Mode.

C-buttons are accessed by holding **R2** and pressing a face button:

| Combo | N64 C-button |
|-------|-------------|
| R2 + X | C-Up |
| R2 + B | C-Down |
| R2 + Y | C-Left |
| R2 + A | C-Right |

### Controls (Smart Pro / Smart Pro S)

Both analog sticks and the d-pad work natively — left stick controls the N64 analog, right stick controls C-buttons, and the d-pad maps to the N64 d-pad. No special configuration needed.

### Shortcuts

You can assign buttons to common actions like fast forward, quick save/load, rewind, and screenshots. Go to Options → Shortcuts and set any face or shoulder button for each action.

## Technical documentation

For build instructions, patch details, data paths, and other developer-facing information, see [TECHNICAL.md](TECHNICAL.md).

### Debug Logging

Logs will be written to the`$SDCARD_PATH/.userdata/$PLATFORM/logs/` folder.
