# Gmail (native macOS wrapper)

A small SwiftUI + WebKit app that wraps [mail.google.com](https://mail.google.com) in its own
window, like the "install as app" option in Chrome, but native and Chrome-free.

## Features

- Persistent sign-in (cookies live in the app's own WebKit data store)
- Google sign-in and SSO redirects work (Safari-style user agent)
- Links you click that leave Gmail open in your default browser; Google sign-in and
  "compose in new window" popups stay in-app
- Unread inbox count as a Dock badge
- Gmail desktop notifications become macOS notifications; clicking one opens the message
- Attachment downloads go to `~/Downloads` with a completion notification
- Camera and microphone for Google Meet
- Registers as a `mailto:` handler (pick it in System Settings > Desktop & Dock > Default email reader)
- Keyboard shortcuts: ⌘N new message, ⌘R reload, ⌘[ / ⌘] back/forward, ⇧⌘H inbox,
  ⌘= / ⌘- / ⌘0 zoom, ⇧⌘O open in browser, ⇧⌘C copy link

## Build

Requires macOS 14+ and the Swift 5.9+ toolchain (Xcode or Command Line Tools).

```bash
make            # builds build/Gmail.app
make run        # builds and opens it
make install    # copies to /Applications/Gmail.app
```

The bundle is ad-hoc signed, so it runs locally without a developer account.

## Layout

- `Sources/Gmail/GmailApp.swift` – SwiftUI entry point and content view
- `Sources/Gmail/WebViewModel.swift` – WKWebView owner; navigation, popups, downloads, badge
- `Sources/Gmail/NotificationBridge.swift` – `window.Notification` shim → `UNUserNotificationCenter`
- `Sources/Gmail/PopupWindowController.swift` – windows for in-app `window.open`
- `Sources/Gmail/AppCommands.swift` – menu bar items and shortcuts
- `Resources/Info.plist`, `Scripts/make-icon.swift`, `Makefile` – packaging
