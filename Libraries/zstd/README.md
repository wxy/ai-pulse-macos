# zstd

Static arm64 build of Facebook Zstandard 1.5.7 for macOS 14+.

Built from the upstream `lib` target with compression disabled; only the
decompression API needed for DeepSeek Harness journals is linked into AI Pulse.
