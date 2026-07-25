# McReader integration policy

This is McReader's fork of [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire), retained under its [MIT license](LICENSE). The reviewed upstream merge-base is `08d10f50167954821a161df877de9fd785e33557`. McReader's root repository records downstream submodule commit `d882d4784b564c57b5e31e47ca1343efd7234db5`, which already contains the first four embedding commits; these SHAs are different baselines and must not be conflated.

The intended remotes are `origin = git@github.com:ryanmccool/McReader-NetNewsWire.git` and `upstream = https://github.com/Ranchero-Software/NetNewsWire.git`. Verify them before updating. A checkout with `origin` still pointing to Ranchero or with no `upstream` remote is misconfigured and must not be pushed.

## Downstream patch budget

The `mcreader/embedding` branch may contain only these reviewable patch categories:

1. Mechanical containment: build-target, resource, lifecycle, and namespace wiring necessary to present NetNewsWire's existing iOS UIKit application inside McReader.
2. McReader-owned storage/defaults/CloudKit injection and direct-push result propagation required to keep the feature isolated.
3. Capability guards that prevent contained code from owning process-global behavior.
4. Deterministic resource/localization routing with no visual or copy redesign.
5. A future website-highlight post action, after its API contract is approved.
6. This policy/documentation and focused containment tests.

Do not restyle, port to SwiftUI, replace NetNewsWire storage/sync, or change its feed-reader behavior. McReader owns the host app delegate, CarPlay, badge, and its separate library/CloudKit database. McReader aggregates application lifecycle across scenes; each scene retains its own NetNewsWire host/coordinator.

## Updating upstream

1. Confirm `origin` is the McReader fork and `upstream` is Ranchero. Fetch both remotes.
2. Select and record an explicit upstream SHA. Use `git merge-base` to prove its relationship to the prior upstream merge-base; do not substitute the root repository's downstream submodule SHA.
3. Create a temporary branch at the selected upstream SHA and replay the downstream patch series. Run `./buildscripts/updateSecrets.sh` when a local build needs the ignored `Modules/Secrets/Sources/Secrets/SecretKey.swift`; never commit that generated file.
4. Inspect the complete tracked and untracked diff against the selected upstream SHA. Only the manifest categories below are allowed.
   McReader's root `scripts/verify_netnewswire_fork.py` enforces the exact-path manifest in
   `scripts/netnewswire_fork_allowlist.json`; update that policy only as part of the same review.
5. Run the `NetNewsWireFeature` scheme (all `NetNewsWireFeatureTests`), applicable upstream/package tests, McReader focused tests, iPhone/iPad UI smoke, project/diff checks, and runtime/archive verifier.
6. Advance McReader's submodule pointer in a separate reviewed change. Never combine an upstream refresh with website highlights or unrelated feed UI/behavior changes.

## Current downstream patch manifest

- **Target, products, and tests:** `NetNewsWire.xcodeproj/project.pbxproj`, `xcconfig/NetNewsWire_feature_target.xcconfig`, and `NetNewsWire.xcodeproj/xcshareddata/xcschemes/NetNewsWireFeature.xcscheme` add the dynamic iOS feature, unhosted `NetNewsWireFeatureTests`, resources, `MCREADER_EMBEDDED`, and Designed-for-iPad eligibility while keeping Catalyst disabled.
- **Configuration and host boundary:** `iOS/Embedding/NetNewsWireFeatureConfiguration.swift`, `NetNewsWireFeatureRuntime.swift`, and `NetNewsWireFeatureHost.swift` define the one-time environment, contained capabilities, recoverable host construction, process/application lifecycle, scene lifecycle, and push entry point.
- **Entrypoint and host-global containment:** `iOS/AppDelegate.swift`, `iOS/AppDefaults.swift`, `iOS/SceneDelegate.swift`, `iOS/SceneCoordinator.swift`, `iOS/AccountStats/AccountStatsView.swift`, notification settings/inspector routes, and `Shared/Activity/ActivityManager.swift` suppress the embedded entrypoint and guard notification, badge, background-task, quick-action, extension/widget, restoration, standalone-delegate, and activity/Spotlight ownership.
- **Storage/default namespaces:** `Modules/RSCore/Sources/RSCore/NetNewsWireEnvironment.swift`, `AppConfig.swift`, `Platform.swift`, `iOS/AppDefaults.swift`, `Modules/Account/.../AccountSettings.swift`, `AccountManager.swift`, `Modules/RSWeb/.../DownloadSession.swift`, `Shared/ArticleStyles/ArticleThemeDownloader.swift`, `Shared/Extensions/ArticleUtilities.swift`, and `CacheCleaner.swift` route data, caches, themes, temporary assets, refresh state, and defaults through the injected roots/suite while preserving standalone fallbacks.
- **CloudKit isolation and push results:** `Modules/Account/Sources/Account/Account*.swift`, all account delegate conformances, `Account/CloudKit/*.swift`, `Modules/CloudKitSync/.../CloudKitZone.swift`, `iOS/AppDelegate.swift`, and `Mac/AppDelegate.swift` inject the exact container/defaults, match container plus zone, aggregate applied changes, propagate errors, and preserve standalone default-container behavior.
- **Bundle and resources:** `Modules/RSCore/.../Bundle+NetNewsWire.swift`, `UIStoryboard+RSCore.swift`, `Shared/Assets.swift`, article rendering/styles, `DefaultFeedsImporter.swift`, keyboard/nib loaders, and the feature resource phase resolve upstream storyboards, themes, assets, HTML/CSS/JS, OPML, keyboard plists, nibs, and localized tables from the configured framework bundle. Shared named-image accessors retain their original standalone macOS lookup while selecting the configured bundle on iOS.
- **Mechanical localization:** `NNWLocalizedString` and the feature-compiled `iOS/` and `Shared/` localization call sites route existing strings through the configured bundle. `Shared/Localizable.xcstrings` changes only emission state needed to produce the development localization; copy and feed behavior are unchanged.
- **Test seam only:** `iOS/RootSplitViewController.swift` adds `netnewswire.root` as the sole production accessibility identifier for McReader's non-network smoke test.
- **Focused tests:** `Tests/NetNewsWireFeatureTests/` covers configuration/capabilities, storage/defaults, resources/localization, CloudKit, lifecycle, and host-global containment. The current feature suite is 36 tests, including a real embedded-bundle image accessor check.
- Generated `Modules/Secrets/Sources/Secrets/SecretKey.swift` remains development-only and untracked; builds regenerate it locally via `./buildscripts/updateSecrets.sh`.

The measured app closure is 17 dynamic frameworks. `RSCoreObjC` and `RSDatabaseObjC` are static target/object dependencies inside `RSCore` and `RSDatabase`; they are not separate runtime frameworks. The transitive Zip product is dynamic and must be present. Xcode native embed/sign phases own the closure. Do not restore a DerivedData copy script and do not use `codesign --deep`.
