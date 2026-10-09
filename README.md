<p align="center"><img src="assets/icon.svg" width="160" alt="wp"></p>

<h1 align="center">wp</h1>

A minimal macOS wallpaper switcher. Displays images across all monitors, sits below Finder's desktop layer, and stays out of your way.

## Features

- Spans all connected displays
- Crossfade transitions between images
- Blur mode (GPU-accelerated via Metal + CoreImage)
- Shuffle mode
- Status bar menu
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
| Status bar → Next Image (`]`) | Advance to next image |
| Status bar → Previous Image (`[`) | Go back one image |
| Status bar → Blur (`b`) | Toggle blur |
| Status bar → Shuffle (`s`) | Toggle shuffle (reshuffles on enable) |
| Double-click desktop | Toggle blur |

## HTTP API

Set the `PORT` environment variable to enable the HTTP control server:

```sh
PORT=9876 wp ~/Pictures/wallpapers/
```

| Endpoint | Action |
|---|---|
| `GET /next` | Next image |
| `GET /prev` | Previous image |
| `GET /blur` | Toggle blur |

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

Push a `v*` tag to trigger the GitHub Actions release workflow, which builds both architectures and creates a draft release:

```sh
git tag v1.0.0
git push origin v1.0.0
```
