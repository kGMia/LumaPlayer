# Direct launch repair — 2026-10-21

The supplied app exited before its UI loaded. Local crash reports identified a DYLD missing-library abort for `@rpath/MSAL.framework/Versions/A/MSAL`, referenced by `IIVE Player.debug.dylib`. The embedded framework existed, but the target lacked the bundle Frameworks runtime search path. Xcode's launch environment concealed this packaging error.

Both Debug and Release now include `@executable_path/../Frameworks` in `LD_RUNPATH_SEARCH_PATHS`. No signing entitlements or system security settings were removed.

Basic verification:

- Xcode Debug build succeeded (`benchmarks/results/app-linkage-build-20261021.log`).
- `scripts/check-app-linkage.py` traverses the arm64 recorded Mach-O dependencies without launching the app or using Xcode DYLD overrides. The original app failed on MSAL; the rebuilt and delivered app resolve 37 images. This checks this development machine's dependencies, not portability to another Mac.
- Updated `build/IIVE-Player.app` and `build/PersonalTeam/IIVE Player.app`; both pass `codesign --verify --deep --strict` outside the restricted sandbox.
- GUI launch/playback remains for the user to verify. No full regression testing performed.

Xcode recommended settings are separate from the diagnosed launch failure. The installed toolchain reports 27.1, while the project's last upgrade check records 27.0. The exact recommendations were not retrieved: the Xcode workspace query could not pass automatic approval review because that service reported a usage limit. No upgrade marker was changed merely to suppress the notice, and no bulk settings migration was applied. Review the expanded recommendations before changing script sandboxing, concurrency defaults or signing.

The dependency checker can be rerun after any build:

```sh
python3 scripts/check-app-linkage.py 'build/IIVE-Player.app'
```
