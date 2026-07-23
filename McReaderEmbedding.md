# McReader integration policy

This is McReader's fork of [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire), retained under its [MIT license](LICENSE). Ranchero remains the `upstream` remote; the upstream baseline for this integration branch is `08d10f50167954821a161df877de9fd785e33557`.

## Downstream patch budget

The `mcreader/embedding` branch may contain only these reviewable patch categories:

1. Mechanical containment: build-target, resource, lifecycle, and namespace wiring necessary to present NetNewsWire's existing iOS UIKit application inside McReader.
2. A future website-highlight post action, after its API contract is approved.
3. This policy/documentation and targeted containment tests.

Do not restyle, port to SwiftUI, replace NetNewsWire storage/sync, or change its feed-reader behavior. McReader owns the host app delegate, scene lifecycle, CarPlay, badge, and its separate library/CloudKit database.

## Updating upstream

Fetch `upstream`, check out the selected upstream SHA in a temporary branch, replay the small downstream patch series, inspect the resulting diff against upstream, run the NetNewsWire feature build and McReader containment tests, then advance McReader's submodule pointer in a separate reviewed commit.

## Current downstream patch manifest

- `NetNewsWire.xcodeproj/project.pbxproj`, `xcconfig/NetNewsWire_feature_target.xcconfig`: add `NetNewsWireFeature`, an iOS framework target that reuses the upstream iOS + Shared synchronized source/resource groups with the iOS bridging header and `MCREADER_EMBEDDED` compile condition.
- `iOS/AppDelegate.swift`, `iOS/AppDefaults.swift`, `iOS/SceneDelegate.swift`: suppress `@main` in embedded builds, add embedded bootstrap/setup, extract root split/coordinator setup, and gate process-global ownership features when hosted.
- `iOS/Embedding/NetNewsWireFeatureHost.swift`: public host/factory surface that boots the embedded app services and returns the upstream storyboard-backed root controller.
- `Modules/RSCore/Sources/RSCore/Bundle+NetNewsWire.swift`, `Modules/RSCore/Sources/RSCore/UIKit/UIStoryboard+RSCore.swift`: resolve storyboards/resources from the framework bundle when hosted.
- `Shared/Assets.swift`, `Shared/Article Rendering/*`, `Shared/ArticleStyles/*`, `Shared/Importers/DefaultFeedsImporter.swift`, `iOS/KeyboardManager.swift`, `iOS/Add/AddFeedViewController.swift`, `iOS/Settings/SettingsViewController.swift`: route upstream images, colors, HTML/CSS/JS, themes, OPML, keyboard plists, and nib loads through the feature bundle.
- Generated `Modules/Secrets/Sources/Secrets/SecretKey.swift` remains development-only and untracked; builds regenerate it locally via `./buildscripts/updateSecrets.sh`.
