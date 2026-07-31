# McReader integration policy

This is McReader's fork of [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire), retained under its [MIT license](LICENSE). The reviewed upstream merge-base is `5fb251ac745edd4329b96ab9e19940fd352772f8` (`iOS-7.1.2-7112`). McReader's root gitlink is the authoritative downstream pin; it and the upstream merge-base are different baselines and must not be conflated.

The intended remotes are `origin = https://github.com/ryanmccool/McReader-NetNewsWire.git` and `upstream = https://github.com/Ranchero-Software/NetNewsWire.git`. Verify them before updating. A checkout with `origin` still pointing to Ranchero or with no `upstream` remote is misconfigured and must not be pushed.

## Downstream patch budget

The `mcreader/embedding` branch may contain only these reviewable patch categories:

1. Mechanical containment: build-target, resource, lifecycle, and namespace wiring necessary to present NetNewsWire's existing iOS UIKit application inside McReader.
2. McReader-owned storage/defaults/CloudKit injection and direct-push result propagation required to keep the feature isolated.
3. Capability guards that prevent contained code from owning process-global behavior.
4. Deterministic resource/localization routing with no visual or copy redesign.
5. Reviewed repairs to the dedicated Feeds CloudKit account, including exact-URL OPML upsert, deterministic identities, idempotent deletion, and explicit account reset.
6. Persisted feed-article highlights through immutable per-scene plain-value callbacks. McReader owns synced annotation storage; NetNewsWire owns article identity, anchoring, rendering, selection/edit-menu integration, and highlight posting assembly.
7. This policy/documentation and focused containment tests.

Do not restyle, port to SwiftUI, replace NetNewsWire storage/sync, or change its feed-reader behavior beyond the approved highlight integration. Highlight callbacks carry only opaque article/anchor values and source snapshots; they must not expose NetNewsWire models or permit McReader RSS/feed/article tables. McReader owns the host app delegate, CarPlay, badge, and its separate library/CloudKit database. McReader aggregates application lifecycle across scenes; each scene retains its own NetNewsWire host/coordinator.

## Updating upstream

1. Confirm `origin` is the McReader fork and `upstream` is Ranchero. Fetch both remotes.
2. Select and record an explicit upstream SHA. Use `git merge-base` to prove its relationship to the prior upstream merge-base; do not substitute the root repository's downstream submodule SHA.
3. Create a temporary branch at the selected upstream SHA and replay the downstream patch series. Run `./buildscripts/updateSecrets.sh` when a local build needs the ignored `Modules/Secrets/Sources/Secrets/SecretKey.swift`; never commit that generated file.
4. Inspect the complete tracked and untracked diff against the selected upstream SHA. Only the manifest categories below are allowed.
   McReader's root `scripts/verify_netnewswire_fork.py` enforces the exact-path manifest in
   `scripts/netnewswire_fork_allowlist.json`; update that policy only as part of the same review.
5. Run the `NetNewsWireFeature` scheme (all `NetNewsWireFeatureTests`), applicable upstream/package tests, McReader focused tests, iPhone/iPad UI smoke, project/diff checks, and runtime/archive verifier.
6. Advance McReader's submodule pointer in a separate reviewed change. Never combine an upstream refresh with feed highlights or unrelated feed UI/behavior changes.

## Current downstream patch manifest

- **Target, products, and tests:** `NetNewsWire.xcodeproj/project.pbxproj`, `xcconfig/NetNewsWire_feature_target.xcconfig`, and `NetNewsWire.xcodeproj/xcshareddata/xcschemes/NetNewsWireFeature.xcscheme` add the dynamic iOS feature, unhosted `NetNewsWireFeatureTests`, resources, `MCREADER_EMBEDDED`, and Designed-for-iPad eligibility while keeping Catalyst disabled.
- **Configuration and host boundary:** `iOS/Embedding/NetNewsWireFeatureConfiguration.swift`, `NetNewsWireFeatureRuntime.swift`, and `NetNewsWireFeatureHost.swift` define the one-time environment, contained capabilities, recoverable host construction, process/application lifecycle, scene lifecycle, and push entry point.
- **Feed highlights:** `iOS/Embedding/NetNewsWireHighlightActions.swift`, the `iOS/Article/ArticleHighlight*` files, `WebViewController.swift`, `PreloadedWebView.swift`, `article_highlights.js`, `WebViewConfiguration.swift`, and `core.css` implement the immutable per-scene callback boundary, opaque stable article/anchor values, generation-scoped restoration, confident cross-rendition matching, standard edit-menu commands, removal, and combined posting. McReader stores and syncs the copied records in its own SQLiteData/CKSyncEngine table; NetNewsWire retains article/rendering ownership and does not use its direct Feeds CloudKit schema for highlights.
- **Entrypoint and host-global containment:** `iOS/AppDelegate.swift`, `iOS/AppDefaults.swift`, `iOS/SceneDelegate.swift`, `iOS/SceneCoordinator.swift`, `iOS/AccountStats/AccountStatsView.swift`, notification settings/inspector routes, and `Shared/Activity/ActivityManager.swift` suppress the embedded entrypoint and guard notification, badge, background-task, quick-action, extension/widget, restoration, standalone-delegate, and activity/Spotlight ownership.
- **Storage/default namespaces:** `Modules/RSCore/Sources/RSCore/NetNewsWireEnvironment.swift`, `AppConfig.swift`, `Platform.swift`, `iOS/AppDefaults.swift`, `Modules/Account/.../AccountSettings.swift`, `AccountManager.swift`, `Modules/RSWeb/.../DownloadSession.swift`, `Shared/ArticleStyles/ArticleThemeDownloader.swift`, `Shared/Extensions/ArticleUtilities.swift`, and `CacheCleaner.swift` route data, caches, themes, temporary assets, refresh state, and defaults through the injected roots/suite while preserving standalone fallbacks.
- **CloudKit isolation and repair:** `Modules/Account/Sources/Account/Account*.swift`, all account delegate conformances, `Account/CloudKit/*.swift`, `Modules/CloudKitSync/.../CloudKitZone.swift`, `iOS/AppDelegate.swift`, and `Mac/AppDelegate.swift` inject the exact container/defaults, match container plus zone, aggregate applied changes, propagate errors, and preserve standalone default-container behavior. OPML imports use exact stored URL strings and deterministic record IDs, deletion distinguishes membership removal from final feed removal, and the explicit retryable reset targets only the Feeds container's `Account` and `Articles` zones.
- **Bundle and resources:** `Modules/RSCore/.../Bundle+NetNewsWire.swift`, `UIStoryboard+RSCore.swift`, `Shared/Assets.swift`, article rendering/styles, `DefaultFeedsImporter.swift`, keyboard/nib loaders, and the feature resource phase resolve upstream storyboards, themes, assets, HTML/CSS/JS, OPML, keyboard plists, nibs, and localized tables from the configured framework bundle. Shared named-image accessors retain their original standalone macOS lookup while selecting the configured bundle on iOS.
- **Reviewed localization:** `NNWLocalizedString` and the feature-compiled `iOS/` and `Shared/` localization call sites route strings through the configured bundle. From the reviewed upstream baseline to downstream HEAD, `Shared/Localizable.xcstrings` adds exactly 25 approved entries and otherwise permits only existing `new`-to-`translated` state transitions. Task 9 added `Highlight`, `Remove Highlight`, and `Post Highlights...`, each with comment `Command`; it reused the existing `Cancel` entry rather than adding one.
- **Test seam only:** `iOS/RootSplitViewController.swift` adds `netnewswire.root` as the sole production accessibility identifier for McReader's non-network smoke test.
- **Focused tests:** `Tests/NetNewsWireFeatureTests/` covers configuration/capabilities, storage/defaults, resources/localization, CloudKit import/reset behavior, lifecycle, host-global containment, and feed-highlight identity, ordering, anchoring, render lifecycle, callbacks, and publishing, including a real embedded-bundle image accessor check.
- Generated `Modules/Secrets/Sources/Secrets/SecretKey.swift` remains development-only and untracked; host build pipelines must run `./buildscripts/updateSecrets.sh` before resolving package dependencies.

The measured app closure is 17 dynamic frameworks. `RSCoreObjC` and `RSDatabaseObjC` are static target/object dependencies inside `RSCore` and `RSDatabase`; they are not separate runtime frameworks. The transitive Zip product is dynamic and must be present. Xcode native embed/sign phases own the closure. Do not restore a DerivedData copy script and do not use `codesign --deep`.
