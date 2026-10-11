<p align="center"><img src="assets/icon.svg" width="160" alt="wp"></p>

<h1 align="center">wp</h1>

A minimal macOS wallpaper switcher. Displays images across all monitors, sits below Finder's desktop layer, and stays out of your way.

## Features

- Spans all connected displays
- Crossfade transitions between images
- Blur mode (GPU-accelerated via Metal + CoreImage)
- Shuffle mode
- Status bar menu and settings window
- Global hotkeys
- Double-click the desktop to toggle blur
- HTTP API for remote control

## Install

Download `wp-arm64.zip` (or `wp-x86_64.zip`) from [Releases](../../releases), unzip it and move `wp.app` to `/Applications`.

The app is ad-hoc signed, not notarized, so clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/wp.app
```

Or build from source:

```sh
./build.sh
```

## Usage

Open `wp.app`. On first launch the settings window opens; add image folders under **Sources**.

Only one instance runs at a time. Launching it again brings up the running instance's settings window.

It can also be started from the terminal with explicit paths, which override the saved sources for that run:

```sh
alias wp=/Applications/wp.app/Contents/MacOS/wp
wp ~/Pictures/wallpapers/
wp ~/Pictures/wallpapers/ ~/Downloads/photo.jpg
```

Pass any combination of image files and directories. Supported formats: `jpg`, `jpeg`, `png`, `gif`, `heic`, `heif`, `tiff`, `tif`, `bmp`, `webp`.

```sh
wp --version
```

## Controls

| Action | Effect |
|---|---|
| Status bar → Next Image | Advance to next image |
| Status bar → Previous Image | Go back one image |
| Status bar → Blur | Toggle blur |
| Status bar → Shuffle | Toggle shuffle (reshuffles on enable) |
| Status bar → Auto Cycle | Toggle automatic image cycling |
| Double-click desktop | Toggle blur |
| Status bar → Settings… (`⌘,`) | Open the settings window |
| Global hotkeys | Set your own in Settings → Hotkeys |

## Settings

Settings are saved between launches.

- **General**: start at login, blur amount and blur when the screen locks or sleeps, auto-cycle interval, HTTP API on/off and port. Toggle Auto Cycle from the status bar menu.
  Start at login registers `wp.app` as a login item, so move it to `/Applications` first; it's unavailable when running the bare binary.
  Manual next/previous actions, shuffle changes, and source changes restart the auto-cycle interval when automatic cycling is enabled.
- **Sources**: add (with + or by dropping folders from Finder), remove and enable/disable image folders. Changes apply immediately.
- **Hotkeys**: system-wide shortcuts for next/previous image (all displays or the one under the cursor), blur and shuffle. No Accessibility permission needed. A warning icon means another app, or another action here, already uses that shortcut.

## HTTP API

Enable it in **Settings → General → HTTP API** and pick a port (default 9876). The status row shows whether the server is listening.

When starting from the terminal, the `PORT` environment variable overrides the saved setting for that run:

```sh
PORT=9876 wp ~/Pictures/wallpapers/
```

| Endpoint | Action |
|---|---|
| `GET /next` | Next image |
| `GET /prev` | Previous image |
| `GET /blur` | Toggle blur |
| `GET /auto-cycle` | Toggle automatic image cycling at the configured interval |

Add `?current_display=true` to `/next` or `/prev` to change only the display under the cursor.

The server listens on all network interfaces, so other devices on your network can reach it.

```sh
curl localhost:9876/next
```

## Build

```sh
ARCH=arm64 VERSION=1.0.0 ./build.sh
# produces: build/arm64/wp.app
```

Supported architectures: `arm64`, `x86_64`.

## Release

Push a `v*` tag to trigger the GitHub Actions release workflow, which builds `wp.app` for both architectures and publishes a release with `wp-arm64.zip` and `wp-x86_64.zip`:

```sh
git tag v1.0.0
git push origin v1.0.0
```
