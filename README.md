# DeployKit

DeployKit is a reusable CMake deployment and bundling helper for Qt-based desktop applications.

It is intended to live as an independent project or submodule. A consuming project names the executable target, and DeployKit uses the built target plus runtime dependency scanning to create install and packaging targets for macOS, Windows, and Linux.

## Current API

Add DeployKit to the parent build, then include the module and configure bundling:

```cmake
add_subdirectory(path/to/DeployKit)
include(DeployKit)

deploykit_configure_bundling(MyApp
    LIBPATHS
        /absolute/path/to/runtime/search/path
)
```

`deploykit_configure_bundling(<target>)` installs the target after each target build and creates a `Bundle<target>` custom target for manual re-bundling. The default output is `${CMAKE_SOURCE_DIR}/build/bundle` on macOS and `${CMAKE_BINARY_DIR}/bundle` on Linux and Windows.

By default, DeployKit preserves an existing bundle directory so unchanged files can remain in place across incremental installs. Configure with `-DDEPLOYKIT_CLEAN_BUNDLE=ON` when a clean bundle directory is required before install. On macOS, clean bundle removal clears extended attributes first so Finder-created metadata does not block stale bundle deletion.

## Arguments

- `LIBPATHS`: extra directories used by deployment tools and CMake runtime dependency scanning.
- `EXTRA_LIBS`: optional CMake targets or absolute library files that are not discoverable from the main executable.
- `EXTRA_FILES`: optional runtime files or directories copied into the platform runtime area.
- `ANALYZE_BINARIES`: optional already-installed helper binaries to inspect during recursive dependency scanning.
- `MACOSX_ICON`: parsed by the API but not implemented yet.
- `VS_BUILD_TOOLS_BOOTSTRAPPER`: optional Windows Build Tools bootstrapper packaged with the application.
- `VS_BUILD_TOOLS_MSVC_COMPONENT`: Visual Studio Installer component ID exposed as an optional installer prerequisite.
- `VS_BUILD_TOOLS_SDK_COMPONENT`: Windows SDK component ID exposed as a separate optional installer prerequisite.

## Platform Behavior

- macOS: installs an app bundle, runs `macdeployqt` when available, copies extra libraries into `Contents/Frameworks`, runs recursive dependency scanning, and stages DragNDrop DMGs with only the `.app` at the image root.
- Windows: installs each configuration under its own bundle subdirectory, copies extra libraries next to the executable, runs `windeployqt` when available, and recursively copies non-system runtime dependencies. The IFW package keeps the application required and exposes missing MSVC and Windows SDK prerequisites separately. Debug bundles skip release-only VTK Qt runtimes.
- All platforms place generated bundle contents below a configuration subdirectory such as `Debug` or `Release` to avoid runtime mixing when one build tree produces multiple configurations.
- Linux: installs the executable, copies selected Qt plugin directories into `plugins` including Wayland client graphics integrations, writes `qt.conf`, installs extra libraries under `lib`, runs recursive dependency scanning, and rewrites bundled ELF RPATH/RUNPATH entries with `patchelf`.
- CPack is configured as `DragNDrop` on macOS, `ZIP` on Windows, and `TGZ` on Linux.

## Current Limitations

- Product-specific files that are loaded dynamically without a binary link edge cannot be inferred from the CMake target graph.
- Consumers must pass those product-specific dynamic assets through `EXTRA_FILES`; DeployKit should not hardcode SDK names such as Basler pylon or VTK.
- Linux Qt plugin selection is fixed to a small default list.
- Linux Qt plugin discovery depends on `Qt::qmake -query QT_INSTALL_PLUGINS` or known Qt CMake install layouts.
- Linux bundling requires `patchelf`; DeployKit fails configuration if it is unavailable because copied ELF files must resolve through the bundled runtime layout.
- `MACOSX_ICON` is accepted by the parser but is not applied.
- Automatic bundling runs after the configured target is built, so incremental builds can spend extra time in install/dependency scanning.
- The module has no standalone test project yet.

## Cleanup Direction

Before treating DeployKit as a general-purpose package, add a small standalone fixture project and make install layout, plugin selection, and automatic bundling opt-in settings.
