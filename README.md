# DeployKit

DeployKit is a CMake deployment and bundling helper for Qt-based desktop applications.

The bundle staging paths are target-driven and can be consumed independently. The current Windows IFW generator is not yet fully reusable: it still embeds legacy product identity, URL, shortcut text, and component assumptions. Use `WINDOWS_PACKAGE_FORMAT=NONE` for a neutral staged bundle until those values become required consumer inputs.

## Current API

Add DeployKit to the consumer build, then include the module and configure bundling:

```cmake
add_subdirectory(path/to/DeployKit)
include(DeployKit)

deploykit_configure_bundling(MyApp
    LIBPATHS
        /absolute/path/to/runtime/search/path
)
```

`deploykit_configure_bundling(<target>)` creates a `Bundle<target>` custom target for explicit deployment. Traditional single-executable consumers also install after each target build; a configured Windows launcher already requires the explicit target. Pass `EXPLICIT_BUNDLE_ONLY` when any other consumer always invokes `Bundle<target>` so a fresh explicit bundle build performs the deployment graph once. The default output is `${CMAKE_BINARY_DIR}/bundle` on every platform.

By default, DeployKit preserves an existing bundle directory so unchanged files can remain in place across incremental installs. Configure with `-DDEPLOYKIT_CLEAN_BUNDLE=ON` when a clean bundle directory is required before install. On macOS, clean bundle removal clears extended attributes first so Finder-created metadata does not block stale bundle deletion.

## Arguments

- `LIBPATHS`: extra directories used by deployment tools and CMake runtime dependency scanning.
- `EXPLICIT_BUNDLE_ONLY`: make `Bundle<target>` the sole install entry point by disabling the otherwise applicable post-build install.
- `EXTRA_LIBS`: optional CMake targets or absolute library files that are not discoverable from the main executable.
- `EXTRA_FILES`: optional runtime files or directories copied into the platform runtime area; macOS framework directories also have their top-level executable dependency-scanned.
- `ANALYZE_BINARIES`: optional already-installed helper binaries to inspect during recursive dependency scanning.
- `MACOS_PLUGIN_TARGETS`: optional module targets installed under `Contents/PlugIns`. A target may provide `DEPLOYKIT_MACOS_PLUGIN_DESTINATION`, `DEPLOYKIT_MACOS_PLUGIN_RUNTIME_DIRECTORIES`, and, when package metadata is needed, both `DEPLOYKIT_MACOS_PLUGIN_MANIFEST` and `DEPLOYKIT_MACOS_PLUGIN_ICON`; DeployKit installs all package metadata and declared runtime directories before final signing.
- `MACOSX_ICON`: parsed by the API but not implemented yet.
- `IFW_COMPONENT_MANIFEST`: optional configured CMake manifest that partitions an already validated Windows bundle into independently versioned IFW components.
- `WINDOWS_PACKAGE_FORMAT`: `IFW` (default), `NSIS`, or `NONE`. Use `NONE` when a host-owned installer such as Inno Setup consumes the staged bundle directly.
- `VS_BUILD_TOOLS_BOOTSTRAPPER`: optional Windows Build Tools bootstrapper packaged with the application.
- `VS_BUILD_TOOLS_MSVC_COMPONENT`: Visual Studio Installer component ID exposed as an optional installer prerequisite.
- `VS_BUILD_TOOLS_SDK_COMPONENT`: Windows SDK component ID exposed as a separate optional installer prerequisite.
- `DEPLOYKIT_MACOS_ADHOC_SIGNING`: macOS ad-hoc signing; enabled by default so local standalone bundles contain a consistent executable/dependency signature set.
- `MACOS_TRANSIENT_FILES`: macOS files copied next to the executable during development but removed before bundle signing.
- `MACOS_CPACK_EXCLUDE_PATHS`: safe app-relative paths removed only from the copied DragNDrop app. With ad-hoc signing enabled, DeployKit re-signs the filtered app before strict verification.

## Platform Behavior

- macOS: installs an ad-hoc signed standalone app bundle by default, runs `macdeployqt`, copies extra libraries into `Contents/Frameworks`, runs recursive dependency scanning, signs the finished app, and stages DragNDrop DMGs with only the `.app` at the image root. The clean temporary signing copy is strict-verified; the installed source copy is integrity-verified because FileProvider workspaces can reattach metadata after signing, while DMG staging removes Finder, resource-fork, and FileProvider provenance metadata before strict verification. Set `DEPLOYKIT_MACOS_ADHOC_SIGNING=OFF` only for unsigned diagnostics; production distribution still needs appropriate Developer ID signing and notarization.
- Windows: installs each configuration under its own bundle subdirectory, copies extra libraries next to the executable, runs `windeployqt` when available, and recursively copies non-system runtime dependencies. Repeated development installs keep ordinary file synchronization active but skip the expensive deployment and recursive-closure passes when their import signatures and managed outputs are unchanged; a missing or invalid stamp falls back to a complete pass. `WINDOWS_PACKAGE_FORMAT=NONE` stops after bundle staging while preserving an optional Build Tools bootstrapper at `tools/installer`; the host installer owns prerequisite UI and product registration. Debug bundles skip release-only VTK Qt runtimes.
- The main IFW component refreshes the global ordered `ProductVersion` and updates the matching Windows uninstall `DisplayVersion` from `DEPLOYKIT_PRODUCT_DISPLAY_VERSION` plus `EstimatedSize` after extraction, so prerelease labels and installed footprint remain accurate.
- A Windows IFW manifest defines `DEPLOYKIT_IFW_COMPONENTS`, `DEPLOYKIT_IFW_DEFAULT_COMPONENT`, per-component metadata, and non-overlapping relative-path regular expressions. Unmatched files belong to the default component; overlapping ownership fails packaging. `DEPLOYKIT_IFW_UPDATE_COMPONENTS` is written to `ifw-update-components.txt` for release tooling.
- Stable runtime components may set `DEPLOYKIT_IFW_COMPONENT_<Name>_CACHE_ARCHIVE` to reuse an `archivegen` payload under `build/ifw-archive-cache/<configuration>/<component>/<version>/<content-hash>`. Nested bundle paths are staged as a directory tree before compression so plugin/runtime layouts remain intact. Cache publication is atomic; a failed copy or compression cannot leave a reusable partial archive. A changed payload under the same configuration and component version fails packaging instead of silently replacing the cache.
- Components may set `DEPLOYKIT_IFW_COMPONENT_<Name>_HIDE_DURING_INSTALL` to stay implicit in the initial installer while remaining visible when MaintenanceTool runs in updater mode.
- All platforms place generated bundle contents below a configuration subdirectory such as `Debug` or `Release` to avoid runtime mixing when one build tree produces multiple configurations.
- Linux: installs the executable, copies selected Qt plugin directories into `plugins` including Wayland client graphics integrations, writes `qt.conf`, installs extra libraries under `lib`, runs recursive dependency scanning, and rewrites bundled ELF RPATH/RUNPATH entries with `patchelf`.
- CPack is configured as `DragNDrop` on macOS, `IFW` on Windows by default, and `TGZ` on Linux. Windows `NONE` intentionally does not include CPack.

## Current Limitations

- The Windows IFW path embeds legacy product-specific metadata and one component identity. It must not be presented as a neutral installer generator until every product value is supplied by the consumer.
- Product-specific files that are loaded dynamically without a binary link edge cannot be inferred from the CMake target graph.
- Consumers must pass product-specific dynamic assets through `EXTRA_FILES`; DeployKit should not acquire new SDK- or renderer-specific knowledge.
- Linux Qt plugin selection is fixed to a small default list.
- Linux Qt plugin discovery depends on `Qt::qmake -query QT_INSTALL_PLUGINS` or known Qt CMake install layouts.
- Linux bundling requires `patchelf`; DeployKit fails configuration if it is unavailable because copied ELF files must resolve through the bundled runtime layout.
- `MACOSX_ICON` is accepted by the parser but is not applied.
- Automatic bundling runs after the configured target is built unless the consumer selects `EXPLICIT_BUNDLE_ONLY`, so incremental builds can otherwise spend extra time in install/dependency scanning.
- The module has no standalone test project yet.

## Required Hardening

Before treating DeployKit as a general-purpose package, move IFW identity and component defaults to validated consumer inputs, add a small standalone fixture project, and make install layout, plugin selection, and automatic bundling opt-in settings.
