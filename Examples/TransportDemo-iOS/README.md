# TransportDemo (iOS)

The iOS version of the transport-mode demo: the app captures with its own `AVCaptureSession`, encodes with its own
`VTCompressionSession` and `AVAudioConverter`, and appends compressed `CMSampleBuffer`s to an `RTMPStream` that only
packetizes and sends. See `../TransportDemo/README.md` for the pipeline description, the buffer shapes and the
checklist; this app has the same controls in a phone layout.

## Run

1. Open `TransportDemoiOS.xcodeproj` (Xcode 26 / Swift 6). The project references the HaishinKit package two levels up
   as a local package.
2. Select your team under *Signing & Capabilities* and run on a **device** (the simulator has no camera).
3. Start an RTMP server reachable from the phone and set its address in the URL field (default `rtmp://192.168.1.10/live`,
   key `transport`).
4. Tap **Start**, then **Connect**. Watch with `ffplay rtmp://<host>/live/transport`.

## iOS specifics

- Portrait only. The video data output connection is rotated (`videoRotationAngle = 90`) so the encoder receives
  upright 720x1280 frames; the front camera is mirrored on the connection.
- The camera can be switched while publishing; the app asks its encoder for a key frame right after the switch.
- `AVCaptureSession` configures `AVAudioSession` automatically (`automaticallyConfiguresApplicationAudioSession`), so no
  audio session code is needed for capture.
- Camera and microphone usage descriptions are generated into Info.plist from the build settings.
