# Multi streaming
Live streaming the same content to several services at once (for example YouTube and Twitch) with a single encode.

## Overview
A stream (``RTMPStream``, ``SRTStream``, ``RTCStream``) attached directly to a ``MediaMixer`` encodes the mixer
output by itself. Attaching N streams to one mixer therefore runs N video encoders and N audio encoders on the same
frames. ``MediaEncoder`` removes that redundancy: it sits between the mixer and the streams, encodes once and fans
the encoded buffers out to every attached stream.

```
MediaMixer ──raw──▶ MediaEncoder ──encoded──▶ RTMPStream (service A)
                                  ├─encoded──▶ RTMPStream (service B)
                                  └─encoded──▶ SRTStream  (service C)
```

## Usage
```swift
import HaishinKit
import RTMPHaishinKit

let mixer = MediaMixer()
let encoder = MediaEncoder()

let connection1 = RTMPConnection()
let stream1 = RTMPStream(connection: connection1)
let connection2 = RTMPConnection()
let stream2 = RTMPStream(connection: connection2)

Task {
  try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
  try await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))

  // The codec settings live on the encoder and are shared by every attached stream.
  var videoSettings = await encoder.videoSettings
  videoSettings.videoSize = .init(width: 1280, height: 720)
  videoSettings.bitRate = 2_500 * 1000
  try await encoder.setVideoSettings(videoSettings)

  // Streams receive the encoded buffers from the encoder, not from the mixer.
  try await encoder.addOutput(stream1)
  try await encoder.addOutput(stream2)
  await mixer.addOutput(encoder)

  await encoder.startRunning()
  await mixer.startRunning()
}

Task {
  try await connection1.connect("rtmp://a.example.com/live")
  try await stream1.publish("streamKeyA")
}

Task {
  try await connection2.connect("rtmp://b.example.com/live")
  try await stream2.publish("streamKeyB")
}
```

Streams can be added and removed while the encoder is running. A stream that joins later starts with a key frame;
``MediaEncoder/addOutput(_:)`` asks the encoder for one so that the new stream doesn't have to wait for the next GOP.

## Notes
- Attach a stream either to the mixer or to the encoder, never to both. A stream attached to an encoder ignores raw
  buffers for encoding.
- The codec settings are shared. Calling `setVideoSettings`/`setAudioSettings` on any attached stream (for example
  from a ``StreamBitRateStrategy``) forwards the change to the encoder and therefore to every stream. With several
  streams, set a bitrate strategy on only one of them: any stream that lowers the bitrate lowers it for all.
- ``MediaEncoder/addOutput(_:)`` and the setters throw ``MediaEncoder/Error/unsupportedCodec`` when an attached stream
  can't transport the codec. ``SRTStream`` transports AAC only; ``RTCStream`` needs Opus (`channelMap: [0, 0]`) and
  H.264, so set those on the encoder before adding the stream.
- Previews (``MTHKView``, ``PiPHKView``) and ``StreamRecorder`` work on raw buffers; add them to the ``MediaMixer``,
  not to a stream that is fed by the encoder.
- To push ReplayKit or other externally captured buffers without a mixer, call ``MediaEncoder/append(_:)`` for video
  and ``MediaEncoder/append(_:when:)`` for PCM audio.
