# minui-n64.pak

A MinUI Emu Pak for N64, wrapping the standalone `mupen64plus` N64 emulator (version 2.5.9).

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

### Adjusting speed

- Speed up: Press `SELECT + A`. This will speed up the emulator in 5% increments.
- Slow down: Press `SELECT + B`. This will slow down the emulator in 5% increments.

### Debug Logging

To enable debug logging, create a file named debug in `$SDCARD_PATH/.userdata/$PLATFORM/N64-mupen64plus` folder. Logs will be written to the`$SDCARD_PATH/.userdata/$PLATFORM/logs/` folder.

### Emulator settings

To change emulator settings, press and hold the `L2` button while selecting/resuming a game to play. Hold L2 until a menu appears. The following settings can be modified:

- Video Plugin: Allows changing the `mupen64plus` video plugin.
  - default: `rice`
  - options: `rice`, `glide64`
- Aspect Ratio: When `glide64` is selected as the video plugin, this allows changing the aspect ratio
  - default: `4:3`
  - options: `4:3`, `16:9`
- DPAD Mode: Allows changing how the dpad is used in game
  - default: `dpad`
  - options: `dpad`, `joystick`, `joystick on f2`

If the `B` or `MENU` buttons are pressed, the user is returned to the MinUI game selection screen. Settings are managed on a per-game basis, and can be saved for future gameplay, or the game can be started with the current settings as is.

### In-Game saves

Any game that creates in-game saves will generate a `.eep` and `.mpk` file. These will be stored in `$SDCARD_PATH/Saves/N64`.

### Muting Audio

To mute audo, press `SELECT + Y`. Pressing `SELECT + Y` again will unmute audio.

### Quitting

To quit, press the `MENU` button.

### Save states

In addition to in-game saves, this pak supports a single save state. Save states are stored in `$SDCARD_PATH/.userdata/shared/N64-mupen64plus`

- Save: To create a save state, press `SELECT + L2`.
- Load: To load a save state, press `SELECT + R2`.
- Resume: When browsing a game in the MinUI list, if there is a save state, press the `X` button to resume the game at that save state.

### Screenshots

To take a screenshot, press `SELECT + L1`. This will create a screenshot in `/Screenshots` with a sanitized version of the rom name as the screenshot prefix.

### Pause

To pause the game, press `SELECT + X`. Pressing `SELECT + X` again will unpause the game.
