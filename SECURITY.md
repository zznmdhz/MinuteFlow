# Security Policy

## Supported version

Security fixes are applied to the latest release on the `main` branch. Legacy
and binary-only archival releases are retained for historical reference and do
not receive security updates.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. Do
not open a public issue for a vulnerability that could expose credentials,
recordings, transcripts, file paths, or a working exploit.

Include the affected version, impact, reproduction steps, and the smallest
sanitized proof of concept possible. Do not include real API keys, private
audio, meeting content, Keychain exports, or signing certificates.

## Important trust boundaries

MinuteFlow handles macOS recording permissions, local meeting files, Keychain
credentials, user-configured network endpoints, remote audio transcription,
and AI-generated text. Security reports involving request authentication,
endpoint validation, credential persistence, unsafe file operations, audio or
transcript disclosure, dependency or release tampering, and untrusted model
output are in scope.
