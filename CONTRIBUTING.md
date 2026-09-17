# Contributing to MinuteFlow

Thank you for helping improve MinuteFlow. Focused bug fixes, tests,
documentation improvements, and accessibility or privacy enhancements are
welcome.

## Before opening an issue

- Search existing issues and releases first.
- State your macOS version, Mac architecture, MinuteFlow version, and whether
  the problem affects system audio, microphone audio, transcription, or both.
- Include reproducible steps and sanitized diagnostics.
- Never attach private recordings, transcripts, API keys, Keychain exports, or
  meeting metadata.

## Pull requests

1. Open an issue first for large behavioral or architectural changes.
2. Keep each pull request focused on one problem.
3. Add or update tests for changed behavior.
4. Preserve raw recordings and recognition evidence; derived processing must
   not silently overwrite source data.
5. Keep recording independent from remote AI availability. Network or model
   failures must not stop or discard a recording.
6. Do not add hard-coded credentials, private endpoints, user data, generated
   recordings, or signing material.

## Development checks

Use Xcode with a Swift 6.3-compatible toolchain. Before submitting a pull
request, build the macOS target and run the test suite when your toolchain
supports it:

```bash
swift test
```

If an environment or toolchain issue prevents a check, describe it accurately
in the pull request instead of reporting the source as verified.
