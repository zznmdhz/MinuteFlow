# MinuteFlow for Mac

[Simplified Chinese](README.md) | English

MinuteFlow is an open-source, native macOS 14+ meeting recorder and
transcription app. It captures system audio and microphone audio as separate
local tracks, creates a synchronized playback file, and can send short audio
segments to a user-configured AI service for transcription and meeting notes.

## Highlights

- Native SwiftUI/AppKit application built with Swift 6.
- Separate ScreenCaptureKit system-audio and AVAudioEngine microphone tracks.
- Timeline-aware mixing with pause, resume, gap alignment, and peak protection.
- Near-real-time transcription with voice activity detection, bounded queues,
  retries, and recoverable pending segments.
- Local acoustic speaker clustering and editable speaker labels.
- Editable transcripts, normalized copies, AI-formatted documents, and meeting
  summaries without overwriting the original recognition evidence.
- Menu-bar recording controls, history, playback, rename, deletion, Finder
  access, permission guidance, and recording diagnostics.
- API credentials stored in macOS Keychain, with an explicit encrypted-file
  fallback that requires user confirmation.

## Privacy model

Raw M4A recordings, metadata, transcripts, and summaries are stored locally.
When transcription is enabled, short WAV segments are sent only to the AI
endpoint configured by the user. When summarization is enabled, the final
transcript text is sent to the configured text model. MinuteFlow does not ship
with an API key and does not silently enable remote processing.

## Supported AI services

MinuteFlow supports Xiaomi MiMo Token Plan endpoints and services compatible
with the OpenAI audio transcription and Chat Completions request formats. The
ASR and text model names are configured separately because they serve different
tasks, while the connection URL and credential can be shared.

## Install

Download the current macOS package from the
[latest release](https://github.com/zznmdhz/MinuteFlow/releases/latest).
Current preview packages use a stable local signing identity for repeatable
testing on the maintainer's Mac; they are not Developer ID notarized for broad
distribution. For development or independent verification, build from source.

## Build and test

1. Open `MinuteFlow.xcodeproj` in Xcode.
2. Select your development team and the **My Mac** destination.
3. Build and run. The first recording requires microphone and screen/system
   audio permissions.

The Swift package manifest targets Swift 6.3. With a matching toolchain, run:

```bash
swift test
```

## Data location

Meeting data is stored under:

```text
~/Library/Application Support/MinuteFlow/Sessions/
```

Unfinished transcription segments are preserved under
`PendingTranscriptions/` so model or network failures do not destroy the
original recording.

## Contributing and security

Bug reports, reproducible diagnostics, tests, and focused pull requests are
welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.
Please report security-sensitive issues according to
[SECURITY.md](SECURITY.md), without exposing credentials or private recordings
in a public issue.

## Version history

The main branch contains the maintained v0.11.x line. Recovered source
snapshots from v0.1 through v0.8.0 are available on the `legacy-history`
branch. v0.9.0 and v0.10.0 are preserved as binary-only releases because no
independently verifiable source snapshots were found.

## License

MinuteFlow is released under the [MIT License](LICENSE).
