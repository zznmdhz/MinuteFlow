# Contributing to MinuteFlow

Thank you for helping improve MinuteFlow. Focused bug fixes, tests,
documentation improvements, and accessibility or privacy enhancements are
welcome.

## Before opening an issue

- Search existing issues and releases first.
- State your OS version, architecture, MinuteFlow version, and whether
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

## Paired macOS and Windows changes

`version.json` is the release version source. Update it together with the Mac
settings in `project.yml`; Windows reads it through `Directory.Build.props`.
Every shared feature or bug fix must update both platform implementations, or
explain the platform-specific exception in `docs/platform-feature-matrix.md`.

Run `node scripts/check-version.mjs`, `bash scripts/check-regressions.sh`, and
`dotnet run --project windows/tests/MinuteFlow.Core.Tests -c Release`.
Windows uses WPF/.NET 10 and NAudio; the Mac app retains SwiftUI and native
audio. A single tag builds both applications. GitHub publishes only after
both jobs succeed. Hardware capture tests are distinct from synthetic tests.
Use the same release notes for both platform packages and document any
platform differences and signing status. Do not publish a one-platform
release under a paired release tag.
