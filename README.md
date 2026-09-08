# Electron + XLang build workspace

This repository builds and validates an Electron distribution whose main
process can import XLang modules through:

```js
const { xlang } = require('electron/main')
```

The Electron fork contains the JavaScript facade and Chromium-side native
binding. A separately compiled, versioned C ABI bridge keeps Electron's GN
toolchain isolated from XLang's CMake toolchain.

## Workspace layout

After bootstrap, the useful source folders appear directly at the repository
root:

```text
electron-build/
|-- electron/       Electron fork (directory alias)
|-- chrome/         Chromium browser sources (directory alias)
|-- third_party/    Chromium dependencies (directory alias)
|-- config/         pinned revisions and GN arguments
|-- scripts/        bootstrap, build, test, and package drivers
|-- tests/          package and Electron/XLang smoke tests
|-- out/            generated native outputs
`-- artifacts/      packaged Electron + XLang distributions
```

Chromium's tools require an internal checkout named `src` and give that
checkout its own Git metadata. Bootstrap keeps it under the ignored
`.chromium/` build-state directory and creates the three direct aliases above.
The public `electron-build` repository therefore stays small and does not
track Chromium's source tree.

XLang remains a separate sibling checkout:

```text
CantorAI/
|-- electron-build/
`-- xlang/
```

Create that sibling checkout from the XLang repository before running the
build:

```powershell
git clone https://github.com/CantorAI/xlang.git D:\CantorAI\xlang
```

The checkout must contain the commit recorded in `config/xlang.ref`; it may be
on any branch because the build validates the exact commit rather than a
branch name. Pass `-XLangRoot` to the scripts when using another location.

No application or product-specific modules are part of this repository.

## Pinned sources

The exact source revisions live in:

- `config/electron.ref`
- `config/xlang.ref`

`bootstrap.ps1` and `build.ps1` reject mismatched or dirty source trees by
default. This prevents a package from silently combining different revisions.
Explicit dirty-source switches exist for local development, but release
artifacts should always use clean pinned commits.

## Windows prerequisites

- Windows 10 or 11, x64
- Visual Studio 2022 with Desktop development with C++
- Windows 10/11 SDK and Debugging Tools
- Git with long-path support
- Python 3
- Node.js supported by the pinned Electron revision
- Chromium `depot_tools`
- At least 200 GiB of free disk space for a clean checkout and build

The current PowerShell driver intentionally selects Visual Studio 2022. The
bridge and package layout are cross-platform, while macOS and Linux build
drivers can be added without changing the C ABI.

An Intel or Apple Silicon Mac can bootstrap Electron's pinned standalone WebRTC
revision and build an Apple Silicon release archive:

```bash
./scripts/bootstrap_macos.sh
./scripts/build_webrtc_macos.sh
```

The source and object trees remain under the CantorAI root `out` directory.
The resulting archive is staged at
`out/deps/macos-arm64-release/webrtc/lib/libwebrtc.a`.
On an older Intel Xcode host, set `MAC_SDK_PATH` to a macOS 15 SDK directory
before running the build script.

## Build

From a PowerShell prompt:

```powershell
cd D:\CantorAI\electron-build

# Checks source pins and installed build tools without downloading anything.
.\scripts\preflight.ps1

# Enables Git long paths, then downloads Chromium and Electron dependencies.
.\scripts\bootstrap.ps1 -ConfigureGit

# Builds xlang_eng + the YAML test module, the bridge and native smoke test,
# the modified Electron executable, runs tests, and creates a distribution.
.\scripts\build.ps1
```

The build uses these isolated output trees:

```text
out/xlang/win32-x64/
out/bridge/win32-x64/
.chromium/src/out/XLangRelease/
```

Concurrent bootstrap, build, and test commands are rejected by a workspace
lock. Generated GN arguments and packaged checksums are written atomically.
The package step copies Electron's `dist.zip` before adding XLang, so the
original Electron distribution remains untouched.

## Test only

```powershell
.\scripts\test.ps1

# Also validate and launch the version-specific packaged distribution.
.\scripts\test.ps1 -VerifyPackage
```

The test driver runs:

1. Python unit tests for deterministic package injection and SHA-256 output.
2. The native C ABI smoke test, including XLang import, object access, events,
   `on`/`off`, and shutdown.
3. The built Electron executable against the main-process JavaScript facade.
4. With `-VerifyPackage`, checksum/ZIP validation followed by the same smoke
   against an isolated extraction using packaged default XLang discovery.

The YAML module and native event module are test-only. Production packages
contain only the bridge, XLang engine, and XLang license notices.

## Distribution

Windows artifacts are written to `artifacts/win32-x64/`. Names contain the
built Electron version plus short Electron and XLang revision IDs. Every ZIP
has a sibling `.sha256` file.

The build first creates the ZIP pair in a unique directory below
`out/package-staging/win32-x64/`. It publishes the pair only after the unit,
native bridge, build-tree Electron, and isolated packaged-distribution checks
pass. A failed run removes its own staging directory and does not replace any
previously published artifact. The next lock-owning build also reclaims
abandoned, run-named staging directories left by a terminated process.
Consequently, `-SkipTests`, `-SkipXLang`, `-SkipBridge`, and `-SkipElectron`
can only be used together with `-SkipPackage`.

To revalidate the newest artifact for the pinned revisions, or select an exact
version, run:

```powershell
.\scripts\verify-package.ps1
.\scripts\verify-package.ps1 `
  -VersionFile .\.chromium\src\out\XLangRelease\version
```

The injected runtime layout is:

```text
resources/xlang/
|-- electron_xlang_bridge.dll
|-- xlang_eng.dll
|-- LICENSE
`-- NOTICE
```

Electron loads this directory by default through `process.resourcesPath`.
There is no bridge manifest.

## JavaScript API

Local module import:

```js
const { app, xlang } = require('electron/main')

app.whenReady().then(async () => {
  const garnet = await xlang.importModule('garnet', {
    fromPath: String.raw`C:\path\to\garnet.dll`
  })

  await garnet.runTest()
  await garnet.dispose()
  await xlang.shutdown()
})
```

Remote import through LRPC uses the same API:

```js
const remote = await xlang.importModule('garnet', {
  fromPath: 'garnet',
  thru: 'lrpc:17654'
})
```

XLang events map to explicit JavaScript subscriptions:

```js
const listener = ({ args, kwargs }) => {
  console.log(args, kwargs)
}

await remote.on('changed', listener)
await remote.off('changed', listener)
```

Every operation is asynchronous and runs in Electron's main process. Returned
XLang objects expose `get`, `set`, `call`, `invoke`, `on`, `off`, and `dispose`.
