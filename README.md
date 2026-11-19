# FrameCast

FrameCast is a native macOS app (Swift and SwiftUI, macOS 14 or later) that mirrors an iPhone or iPad connected by USB, the same way QuickTime does. It shows the device inside a realistic frame on a branded canvas, and it can record video, take screenshots and act as a virtual webcam. Confidentiality overlays can be burned into any of those outputs.

## Features

| Area | What you get |
|---|---|
| **Capture** | USB capture of iPhone and iPad with no drivers, using the same CoreMediaIO route as QuickTime. It reconnects automatically when you plug a device in or out. |
| **Device frame** | The frame can be chosen three ways: **Auto** reads the exact model over USB with libimobiledevice, or falls back to matching the screen resolution. You can also pick a built-in frame manually, or set a default and per-device choices in Settings. Frames rotate with the device. |
| **Frame artwork** | Built-in frames are drawn in code for 16 iPhone and iPad models, with Dynamic Island, notch, camera and Home button details and three colors. You can also import Apple's official bezel PNGs. FrameCast finds the screen area automatically and links each frame to its model. |
| **Recording** | HEVC, H.264 or ProRes in .mov or .mp4, at 24, 30 or 60 fps. The device audio and the Mac microphone are saved as separate tracks. There is a 3-2-1 countdown and an optional trim window after recording. |
| **Screenshots** | PNG at full canvas resolution. Screenshots can also be copied to the clipboard automatically. |
| **Watermark** | Text or image, tiled or single, with adjustable opacity, angle and size. It can cover the whole canvas or just the device screen. |
| **Header & footer** | A header logo with a title and right-side text, plus a confidentiality footer with a colored badge such as "CONFIDENTIAL". |
| **Dynamic tokens** | `{user} {fullname} {date} {time} {datetime} {device} {model} {company} {host} {profile}`. These work in the watermark, header, footer and file names, so a leaked capture can be traced back to who made it and when. |
| **Profiles** | Saved overlay presets for each client or project, which you switch from the toolbar. Three are included: Clean, Confidential and Client Demo. |
| **Burn-in toggles** | You choose whether overlays go into recordings, screenshots and the virtual camera, each separately. Overlays always show in the preview. |
| **Redaction** | Blur, pixelate or solid boxes that stick to the device screen. Drag to add a box and right-click to remove it. |
| **Clean status bar** | Covers the real status bar with 9:41, full battery and Wi-Fi, and matches the app's color automatically. |
| **Presenter tools** | Pen, highlighter, spotlight, zoom lens, and cursor and click highlights. Drawings can fade automatically. |
| **Virtual camera** | A CoreMediaIO camera extension named **FrameCast Camera**, which you can select in Zoom, Teams, Meet or OBS. |
| **Quality of life** | Global hotkeys, a float-on-top window, a canvas background (solid, gradient or image), and canvas sizes such as 1080p, 4K, square, vertical, or fit to the device. |

## Build

You need a Mac with **Xcode 15 or later** and macOS 14 or later.

```bash
cd FrameCast
./bootstrap.sh            # installs XcodeGen if needed, generates FrameCast.xcodeproj, opens Xcode
```

1. In `project.yml`, change `APP_BUNDLE_ID` (`com.example.FrameCast`) to your own ID. Then set `DEVELOPMENT_TEAM` to your Apple Developer Team ID, or pick the team in Xcode under *Signing & Capabilities* for both targets.
2. Select the **FrameCast** scheme and press **Run**.
3. Optional but recommended: `brew install libimobiledevice`. This lets FrameCast read the exact model, such as `iPad16,3`, instead of guessing from the resolution.

**No paid developer account?** Run `./bootstrap.sh --no-vcam` instead. It builds everything except the virtual camera, which is the only part that needs a system-extension entitlement.

## First run

1. Connect the iPhone or iPad with a cable, unlock it, and tap **Trust** if asked.
2. Allow **Camera** access when macOS asks. iOS screen capture is covered by the camera permission.
3. The device appears in the toolbar after a second or two. If it doesn't, choose **Capture › Refresh Devices**, then unplug the device and plug it back in.

## Using Apple's official frames

1. Download **Product Bezels** from [Apple Design Resources](https://developer.apple.com/design/resources/#product-bezels).
2. In FrameCast, go to **Settings › Frames** and click **+**, or use **Frame menu › Import Frame Image…**. Pick the PNGs. You can import portrait and landscape versions.
3. The screen area is detected and the frame is linked to its model. With the frame set to **Auto**, the imported frame is then used automatically whenever that model is connected.

Apple's bezels are licensed for showing your app in marketing materials. Keep them in your own frame library and don't redistribute them inside the app.

## Virtual camera setup

1. Build the full project (not `--no-vcam`) with your team selected.
2. In Xcode, choose **Product › Show Build Folder in Finder**, then copy `FrameCast.app` into **/Applications** and open it from there. macOS only installs camera extensions from apps in /Applications.
3. Go to **Settings › Virtual Camera** and click **Install**, then approve it in **System Settings › General › Login Items & Extensions › Camera Extensions**.
4. Turn on the virtual camera from FrameCast's toolbar, then choose **FrameCast Camera** in your video call app. When FrameCast isn't sending frames, the camera shows a "waiting" card.

After you rebuild, install again to replace the old extension.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌃⌥⌘R / ⇧⌘R | Start or stop recording (the first works system-wide) |
| ⌃⌥⌘S / ⇧⌘S | Screenshot (the first works system-wide) |
| ⌃⌥⌘D | Toggle the pen (system-wide) |
| ⌃⌥⌘K / ⌘K | Clear drawings |
| ⌘1…⌘6 | Pointer, Pen, Highlighter, Spotlight, Zoom, Redact |
| ⌥⌘I | Show or hide the inspector |

## How it works

```
iPhone/iPad ─USB─► CoreMediaIO (screen-capture devices on) ─► AVCaptureSession
                                                          │ video (BGRA)   │ audio
                                                          ▼                ▼
                    RenderLoop (fixed fps) ── Compositor ──┬─► Preview (CALayer)
                    background → frame → content →        ├─► Recorder (AVAssetWriter, +mic track)
                    redactions → status bar → watermark →  ├─► Screenshot (PNG / clipboard)
                    header → footer → presenter layer      └─► VirtualCameraSink ─► Camera Extension
```

| Folder | Contents |
|---|---|
| `Sources/App/Capture` | Turning on screen-capture devices, the AVCapture sessions, and audio retiming |
| `Sources/App/Device` | The model catalog (resolution, bezel, corner radius, status bar) and libimobiledevice lookup |
| `Sources/App/Frames` | Imported frame library and transparent screen-area detection |
| `Sources/App/Overlay` | Profiles, tokens and persistence (`~/Library/Application Support/FrameCast`) |
| `Sources/App/Render` | Compositor, render loop and presenter state |
| `Sources/App/Output` | Recorder, screenshots, file naming and the trim window |
| `Sources/App/VirtualCamera` | Extension installer and the CMIO sink client |
| `Sources/CameraExtension` | The camera system extension (source and sink streams) |

## Known limitations

- **No touch indicators.** USB capture doesn't include touch data. Use the pointer highlight on the Mac instead.
- **Protected video** (FairPlay or HDCP content such as Netflix) shows as black. iOS blocks it, just as it does in QuickTime.
- Only one app can capture a device at a time, so quit QuickTime first.
- The clean status bar is an approximation drawn over the real one. Check it before using a capture in public marketing.
- The canvas size is fixed for each recording. If you rotate the device while recording, it is letterboxed inside the same canvas.

## License

FrameCast is licensed under the [Apache License 2.0 with the Commons Clause](LICENSE).
You may use, copy, modify and share it for free. You may not sell it, or sell a product or
service whose value comes substantially from it.

Copyright © 2026 DevScape.io LLC.
