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
