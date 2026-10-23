# libgit2

Vendored libgit2 **1.9.7**, arm64, macOS 14.0 or later. AI Pulse uses it
for local repository discovery, log walks and tree diffs. SSH, HTTPS, GSSAPI
and NTLM transports are disabled in this build.

## Source and security

- Official tag: [v1.9.7](https://github.com/libgit2/libgit2/releases/tag/v1.9.7)
- Commit: `49e408b3208bc3093757a1c2db938d3590f3f412`
- Source: `https://codeload.github.com/libgit2/libgit2/tar.gz/refs/tags/v1.9.7`
- Source SHA-256: `1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7`
- License: [COPYING](COPYING), GPLv2 with the libgit2 linking exception.

This replaces 1.9.0 and includes the 1.9.5 fix for
[GHSA-27m5-gxxh-x79j / CVE-2026-53585](https://github.com/libgit2/libgit2/security/advisories/GHSA-27m5-gxxh-x79j),
which limits delta result-size allocation before applying instructions,
including when reading local packs. Version 1.9.7 also includes subsequent
maintenance and security fixes. This does not impose an application-wide
memory bound on every valid repository operation.

## Binary layout

`lib/libgit2.1.9.7.dylib`, `lib/libgit2.1.9.dylib` and `lib/libgit2.dylib`
contain the same signed binary. Existing SwiftPM and Xcode references retain
`@rpath/libgit2.1.9.dylib` (compatibility version 1.9.0, current version 1.9.7).
The dSYM has the same UUID as the binary; the former 1.9.0 file and symbols
were replaced. These are distributable dependency assets, not test outputs.

Dylib SHA-256 (all three names):

```
3ac5026263c08474c65f5a49634d6c26aa9ecaab3d9c6d58ae80c9cb25f4726c
```

UUID: `72EE3096-7A01-35EE-85ED-F7DA52048BD2`.
Runtime dependencies are system libz, libiconv and libSystem; no Homebrew
runtime paths are embedded. The ad-hoc signature is replaced by the app's
normal CodeSignOnCopy step when packaging.

## Build recipe

Extract the source into a task directory under `$TMPDIR`. Set `SRC`, `BUILD`
and `OUT` to directories there. The headers are copied from that exact tag.
The build used Xcode's Apple clang and the macOS SDK on macOS 26.6.2.

```sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_INSTALL_NAME_DIR=@rpath \
  "-DCMAKE_C_FLAGS=-fdebug-prefix-map=$SRC=libgit2-1.9.7 -fdebug-prefix-map=$BUILD=libgit2-build" \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF -DBUILD_CLI=OFF \
  -DUSE_SSH=OFF -DUSE_HTTPS=OFF -DUSE_GSSAPI=OFF -DUSE_NTLMCLIENT=OFF \
  -DREGEX_BACKEND=regcomp -DUSE_BUNDLED_ZLIB=OFF \
  -DZLIB_INCLUDE_DIR="$SDK/usr/include" -DZLIB_LIBRARY="$SDK/usr/lib/libz.tbd" \
  -DENABLE_REPRODUCIBLE_BUILDS=ON
cmake --build "$BUILD" --parallel 4
mkdir -p "$OUT"
cp "$BUILD/libgit2.1.9.7.dylib" "$OUT/libgit2.1.9.dylib"
xcrun dsymutil "$OUT/libgit2.1.9.dylib" -o "$OUT/libgit2.1.9.dylib.dSYM"
xcrun strip -S -x "$OUT/libgit2.1.9.dylib"
codesign --force --sign - "$OUT/libgit2.1.9.dylib"
```

Before replacing the vendored files, verify `git_libgit2_version`, header
version, SHA-256, `otool -L`, `LC_BUILD_VERSION`, matching dSYM UUIDs and a
packed-repository log/diff pass. Hashes can differ across toolchains and
build paths; record updated provenance whenever rebuilding.
