# MultiStreamDemo

A macOS demo for the shared-encoder pipeline: camera + microphone → `MediaMixer` → one `MediaEncoder` → N `RTMPStream`s.

It has a second mode, "Encoder per stream (legacy)", that attaches every stream straight to the mixer, so you can compare
the CPU usage of both pipelines with the same number of destinations.

## Run

1. Start a local RTMP server, for example [MediaMTX](https://github.com/bluenviron/mediamtx):
   ```
   docker run --rm -p 1935:1935 -p 8554:8554 bluenviron/mediamtx
   ```
2. Build and run the demo (Xcode 26 / Swift 6 toolchain):
   ```
   cd Examples/MultiStreamDemo
   swift run
   ```
   or `open Package.swift` and run the `MultiStreamDemo` scheme in Xcode. The first launch asks for camera and
   microphone access.
3. Press **Start capture**, then **Connect** on two or three destinations (defaults: `rtmp://localhost/live` with keys
   `stream1`, `stream2`, `stream3`).
4. Watch the streams:
   ```
   ffplay rtmp://localhost/live/stream1
   ffplay rtmp://localhost/live/stream2
   ```

## What to check

- **One encode.** In shared mode the CPU label stays roughly flat when you connect the second and third destination.
  In legacy mode it grows with every destination. Instruments (Video Toolbox / Core Media) shows one
  `VTCompressionSession` vs N.
- **Late joiner.** Connect destination A, wait a few seconds, connect B. B's `ffplay` must show a clean picture from the
  first frame: `MediaEncoder.addOutput` forces a key frame and the stream waits for it.
- **Shared settings.** Change the bitrate slider and press **Set bitrate via stream 1**. The log shows the encoder's
  bitrate following the stream's `setVideoSettings`, and every destination's kbps changes together.
- **Reconnect.** Disconnect and reconnect a destination while the others keep publishing; the others must not glitch.
- **Legacy path.** Switch to "Encoder per stream" (only while nothing publishes) and repeat; behaviour must match the
  previous releases.

## Notes

- The app is an unbundled SwiftPM executable. `Package.swift` embeds `Info.plist` into the binary with
  `-sectcreate __TEXT __info_plist` so macOS can show the camera/microphone permission prompts.
- Destinations use RTMP only; the same `MediaEncoder` can also feed `SRTStream` (AAC only) and `RTCStream`
  (Opus + H.264).
