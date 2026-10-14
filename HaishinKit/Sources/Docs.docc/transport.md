# Transport mode
Using HaishinKit only as the network layer: the app captures and encodes by itself and hands over compressed sample buffers.

## Overview
HaishinKit supports three publishing pipelines, and they coexist in the same framework:

| Pipeline | Who encodes | Setup |
|:-|:-|:-|
| Classic | the stream (one encoder pair per stream) | `mixer.addOutput(stream)` |
| Shared encoder | ``MediaEncoder`` (once for N streams) | `encoder.addOutput(stream)`, `mixer.addOutput(encoder)` — see [Multi streaming](doc://HaishinKit/multistreaming) |
| Transport | the app (VideoToolbox, AudioToolbox, a game engine, …) | `stream.append(compressedSampleBuffer)` |

In transport mode a stream (``RTMPStream``, ``SRTStream``, ``RTCStream``) receives one `CMSampleBuffer` per video
access unit and one `CMSampleBuffer` per audio packet (or several packets) and only packetizes and sends them.
No `MediaMixer` and no ``MediaEncoder`` are involved; multi-streaming is then the app's business (append the same
buffers to several streams).

## Requirements on the buffers
- **Video:** H.264 or HEVC in AVCC/HVCC form (length-prefixed NAL units), exactly what `VTCompressionSession`
  produces. The `formatDescription` must carry the parameter sets (`avcC`/`hvcC`): the stream builds the RTMP
  sequence header / TS parameter sets from it. Key frames must not have the `kCMSampleAttachmentKey_NotSync`
  attachment. The presentation (and, with B-frames, decode) time stamps must be monotonic; the timeline may start
  anywhere, including 0.
- **Audio:** AAC (RTMP, SRT) or Opus (RTMP, WebRTC) packets. A buffer may hold one packet or several, with packet
  descriptions (`CMAudioSampleBufferCreateWithPacketDescriptions`). The format description's
  `AudioStreamBasicDescription` must describe the encoded format (sample rate, channels, `mFramesPerPacket`).
  Audio and video share one timeline.

## Usage
```swift
let connection = RTMPConnection()
let stream = RTMPStream(connection: connection)

Task {
  try await connection.connect("rtmp://example.com/live")
  try await stream.publish("streamKey")
}

// From your VTCompressionSession output handler:
func videoEncoder(didEncode sampleBuffer: CMSampleBuffer) {
  Task { await stream.append(sampleBuffer) }
}

// From your audio encoder (one CMSampleBuffer per AAC packet, or several packets with packet descriptions):
func audioEncoder(didEncode sampleBuffer: CMSampleBuffer) {
  Task { await stream.append(sampleBuffer) }
}
```

Buffers appended before `publish` are not sent, but their formats are remembered so that `onMetaData`
(width, height, codec ids, sample rate) is correct from the start. When nothing was appended before `publish`,
`onMetaData` is sent together with the first sequence header instead.

## Behaviour
- The first video message after `publish` is always a key frame; earlier P/B frames are dropped. Ask your encoder for
  a key frame when you start publishing (`kVTEncodeFrameOptionKey_ForceKeyFrame`).
- When video is expected, audio is held until the first key frame has been accepted so that the RTMP audio and video
  timelines start together.
- `videodatarate`/`audiodatarate` in `onMetaData` come from ``StreamConvertible/videoSettings`` /
  ``StreamConvertible/audioSettings``. Call ``StreamConvertible/setVideoSettings(_:)`` and
  ``StreamConvertible/setAudioSettings(_:)`` with the parameters of your encoder if you want those hints to be
  accurate; the stream's own encoders stay idle.
- ``StreamBitRateStrategy`` still receives network events through ``StreamConvertible/dispatch(_:)``, but changing
  the stream's settings doesn't affect your encoder. Implement your own strategy if you need adaptive bitrate.
- Raw (uncompressed) buffers appended to the same stream are encoded by the stream as in the classic pipeline.
  Don't mix raw and compressed input on one stream.
