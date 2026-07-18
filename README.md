# Pomodorough for iOS

Native SwiftUI client for the local-first Pomodorough timer at [pomodorough.egigoka.me](https://pomodorough.egigoka.me).

## Highlights

- Railway/transit-clock visual system adapted from the production website
- Native Liquid Glass controls on iOS 26+, with iOS 17 material fallbacks
- Google Sign-In challenge/nonce exchange and rotating bearer tokens stored in Keychain
- Optimistic local timer with a durable command queue for offline start, pause, resume, finish, cancel, and clear actions
- Cross-device reconciliation against the server's canonical projection
- Configurable 1–180 minute focus, short-break, and long-break routes
- Optional automatic breaks, with a long break every fourth completed focus run
- Recent account history, sync state, queued-action count, and conflict feedback
- VoiceOver labels, Dynamic Type, native controls, stable list identity, and adaptive iPhone/iPad/macOS layouts
- App icon derived from the production route-clock mark

## Requirements

- Xcode 26.6 or newer
- XcodeGen (`brew install xcodegen`)
- iOS 17+ or macOS 14+

The production Google client ID and callback URL scheme are configured in `project.yml`. The API base URL is `https://pomodorough.egigoka.me`.

## Generate and open

```sh
xcodegen generate
open Pomodorough.xcodeproj
```

## Verify

```sh
xcodebuild -project Pomodorough.xcodeproj \
  -scheme Pomodorough-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  build

xcodebuild -project Pomodorough.xcodeproj \
  -scheme Pomodorough-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  test

xcodebuild -project Pomodorough.xcodeproj \
  -scheme Pomodorough-macOS \
  -configuration Debug \
  build
```

Live authentication requires a Google account accepted by the production backend. Timer actions remain local and queued if sync is temporarily unavailable.
