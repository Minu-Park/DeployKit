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

`deploykit_configure_bundling(<target>)` installs the target after each target build and creates a `Bundle<target>` custom target for manual re-bundling. The default output is `${CMAKE_SOURCE_DIR}/build/bundled` on macOS and `${CMAKE_BINARY_DIR}/bundled` on Linux and Windows.

## Arguments

- `LIBPATHS`: extra directories used by deployment tools and CMake runtime dependency scanning.
- `EXTRA_LIBS`: optional CMake targets or absolute library files that are not discoverable from the main executable.
- `EXTRA_FILES`: optional runtime files or directories copied into the platform runtime area.
- `ANALYZE_BINARIES`: optional already-installed helper binaries to inspect during recursive dependency scanning.
- `MACOSX_ICON`: parsed by the API but not implemented yet.

## Platform Behavior

- macOS: installs an app bundle, runs `macdeployqt` when available, copies extra libraries into `Contents/Frameworks`, and runs recursive dependency scanning.
- Windows: installs the executable, copies extra libraries next to it, and runs `windeployqt` when available.
- Linux: installs the executable, copies selected Qt plugin directories into `plugins`, writes `qt.conf`, installs extra libraries under `lib`, sets install RPATH, and runs recursive dependency scanning.
- CPack is configured as `DragNDrop` on macOS, `ZIP` on Windows, and `TGZ` on Linux.

## Current Limitations

- Product-specific files that are loaded dynamically without a binary link edge cannot be inferred from the CMake target graph.
- Linux Qt plugin selection is fixed to a small default list.
- Linux Qt plugin discovery depends on `Qt::qmake -query QT_INSTALL_PLUGINS` or known Qt CMake install layouts.
- `MACOSX_ICON` is accepted by the parser but is not applied.
- Automatic bundling runs after the configured target is built, so incremental builds can spend extra time in install/dependency scanning.
- The module has no standalone test project yet.

## Cleanup Direction

Before treating DeployKit as a general-purpose package, add a small standalone fixture project and make install layout, plugin selection, and automatic bundling opt-in settings.
