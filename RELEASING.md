# Releasing

Versions follow semver, with Dart's pre-1.0 convention: until 1.0, a minor bump (0.11 to 0.12) may break things, and a patch bump never does. The public API is the tool names, their arguments, the `errorKind` values and the reply shape.

1. Every user-visible change adds a line under `## [Unreleased]` in `CHANGELOG.md`, in the same PR.
2. On an up-to-date `master`, run `dart run tool/release.dart prepare <x.y.z>`. It bumps `pubspec.yaml` and `lib/src/version.dart`, moves the Unreleased entries under `## [x.y.z] - <date>`, and commits on `release/v<x.y.z>`. Push that branch and merge it through a PR.
3. Back on `master` after the merge, run `dart run tool/release.dart tag`. It checks the changelog has the version, then creates and pushes the tag `v<x.y.z>`.
4. The Release workflow checks the tag matches `pubspec.yaml`, runs the tests, and publishes a GitHub Release with that version's changelog section as notes.
