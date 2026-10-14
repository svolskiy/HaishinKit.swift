# MultiStreamDemo (iOS)

The iOS version of the shared-encoder demo: camera + microphone → `MediaMixer` → one `MediaEncoder` → N `RTMPStream`s,
with the "Encoder per stream" legacy mode for a side-by-side CPU comparison. See `../MultiStreamDemo/README.md` for the
pipeline description and the checklist; this app has the same controls in a phone layout.

## Run

1. Open `MultiStreamDemoiOS.xcodeproj` (Xcode 26 / Swift 6). The project references the HaishinKit package two levels
   up as a local package.
2. Select your team under *Signing & Capabilities* (the project ships with an empty `DEVELOPMENT_TEAM`) and run on a
   **device**: the simulator has no camera, so the mixer produces no video there.
3. Start an RTMP server reachable from the phone (for example MediaMTX on your Mac) and replace `192.168.1.10` in the
   destination URLs with its address.
4. Tap **Start**, then **Connect** on each destination. Watch with `ffplay rtmp://<host>/live/stream1`.

## Notes

- Portrait only. The mixer runs with `videoOrientation = .portrait`, so the presets are portrait sizes (720x1280 …).
- The CPU badge shows this process' CPU usage; in shared-encoder mode it should stay flat when a second destination
  connects, in legacy mode it grows per destination.
- Camera and microphone usage descriptions are generated into Info.plist from the build settings; no entitlements are
  needed on iOS for this app.
