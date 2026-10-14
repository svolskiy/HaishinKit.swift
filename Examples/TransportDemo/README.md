# TransportDemo

A macOS demo for the **transport mode**: the app captures and encodes by itself and uses HaishinKit only to packetize
and send.

```
AVCaptureSession ──raw──▶ VTCompressionSession (app) ──H.264/HEVC CMSampleBuffer──▶ RTMPStream.append
                 └─PCM──▶ AVAudioConverter      (app) ──AAC CMSampleBuffer────────▶ RTMPStream.append
```

No `MediaMixer`, no `MediaEncoder`; the stream's own codecs stay idle. The same buffers could be appended to several
streams, but multi-streaming is the app's responsibility in this mode (see `Examples/MultiStreamDemo` for the shared
`MediaEncoder` pipeline).

## Run

1. Start a local RTMP server, for example [MediaMTX](https://github.com/bluenviron/mediamtx):
   ```
   docker run --rm -p 1935:1935 -p 8554:8554 bluenviron/mediamtx
   ```
2. Build and run (Xcode 26 / Swift 6 toolchain):
   ```
   cd Examples/TransportDemo
   swift run
   ```
   or `open Package.swift` and run the `TransportDemo` scheme in Xcode. The first launch asks for camera and
   microphone access.
3. Press **Start capture**, then **Connect** (default `rtmp://localhost/live`, key `transport`).
4. Watch the stream:
   ```
   ffplay rtmp://localhost/live/transport
   ```

## What to check

- **Clean start.** The picture in `ffplay` must be clean from the first frame: `connect()` asks the app encoder for a
  key frame right after `publish`, and the stream drops P-frames until the first IDR anyway.
- **A/V sync.** Clap in front of the camera; audio and video must line up. The stream holds audio until the first
  video key frame so both RTMP timelines start together.
- **onMetaData.** Connect *before* the first encoded frame arrives (press Connect immediately after Start capture):
  the stream sends `onMetaData` with the first sequence header. Connect later: `onMetaData` is built from the formats
  seen before `publish`. Check `width`/`height`/`videocodecid` with `ffprobe rtmp://localhost/live/transport`.
- **Live bitrate.** Move the video slider and press **Bitrate live**: the sent kbps follows without recreating the
  session or restarting the stream.
- **Apply (recreate session).** Changing the resolution or codec recreates the `VTCompressionSession` while publishing;
  the stream sends a new sequence header when the format description changes.
- **Reconnect.** Disconnect and Connect again while capture keeps running.

## Buffer shape produced by the app encoders

- Video: `VTCompressionSession` output as-is (AVCC/HVCC payload, format description with `avcC`/`hvcC`, key frames
  without the `NotSync` attachment, B-frames disabled).
- Audio: one `CMSampleBuffer` per AAC packet, created with `CMAudioSampleBufferCreateWithPacketDescriptions`
  (`mFramesPerPacket = 1024`, presentation time = first input PTS + packets × 1024 / sampleRate).

## Notes

- The app is an unbundled SwiftPM executable. `Package.swift` embeds `Info.plist` into the binary with
  `-sectcreate __TEXT __info_plist` so macOS can show the camera/microphone permission prompts.
