# DeployKit Release Note

## Unreleased

- Correct the README to distinguish reusable bundle staging from the legacy product-specific Windows IFW generator.
- Use consumer-neutral integration wording in the README so the module remains understandable outside any particular application.
- Gate repeated Windows runtime dependency analysis with a validated import and output signature while keeping ordinary install synchronization active.
- Preserve versioned macOS framework symlinks when installing extra framework runtimes, replacing stale payloads before dependency scanning and signing.
- Support consumer-declared macOS DMG exclusions and re-sign the filtered staging copy before strict signature verification.
- Remove FileProvider provenance metadata immediately before strict verification after moving signed macOS bundles.
- Keep strict verification on the clean temporary signing copy and use non-strict signature integrity verification on the FileProvider source copy; distribution DMGs remain strict-verified.
- Allow consumers to make the explicit bundle target the sole install path, avoiding duplicate deployment after a fresh target link.
- Create consumer-declared macOS plugin runtime directories before dependency collection and final signing.
