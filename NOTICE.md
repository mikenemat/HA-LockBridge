# Third-party software notices

HA-LockBridge is licensed under the MIT License (see [LICENSE](LICENSE)).
It depends on or builds upon the following third-party open-source projects:

## Mac Catalyst bridge (`macos-app/`)

| Component | License | Notes |
|---|---|---|
| [SwiftNIO](https://github.com/apple/swift-nio) | Apache 2.0 | HTTP + WebSocket server implementation. © Apple Inc. |
| [Swift Atomics](https://github.com/apple/swift-atomics) | Apache 2.0 | Transitive dependency of SwiftNIO. © Apple Inc. |
| [Swift Collections](https://github.com/apple/swift-collections) | Apache 2.0 | Transitive dependency of SwiftNIO. © Apple Inc. |
| [Swift System](https://github.com/apple/swift-system) | Apache 2.0 | Transitive dependency of SwiftNIO. © Apple Inc. |
| Apple HomeKit Framework | Proprietary | Distributed by Apple as part of macOS / iOSSupport. Used under Apple's developer license. |
| Apple Bonjour / NetService | Proprietary | Same. |

Build tools used to produce the app (not redistributed with it):

| Tool | License | Notes |
|---|---|---|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT | Project-file generation. |
| [Pillow](https://github.com/python-pillow/Pillow) | HPND | Used by `Resources/generate_icon.py` to draw the placeholder app icon. |

## HomeAssistant integration (`custom_components/ha_lockbridge/`)

| Component | License | Notes |
|---|---|---|
| [aiohttp](https://github.com/aio-libs/aiohttp) | Apache 2.0 | HTTP + WebSocket client. © aio-libs. Provided by the HomeAssistant runtime. |
| [voluptuous](https://github.com/alecthomas/voluptuous) | BSD-3 | Config-flow schema validation. Provided by the HomeAssistant runtime. |
| [HomeAssistant](https://github.com/home-assistant/core) | Apache 2.0 | The integration patterns and helper APIs follow HA conventions. |

## Apple-specific notes

This software is not affiliated with, endorsed by, or sponsored by Apple Inc.
"Apple", "Mac", "macOS", "iCloud", "HomeKit", "HomeKey", "Apple Home", "iPhone",
"Apple TV", and related marks are trademarks of Apple Inc. registered in the
U.S. and other countries. References to these terms in this project are
descriptive only and used solely to identify Apple products and services that
this software interoperates with.

## License headers

All source files in this repository are © 2026 Michael Nemat and licensed
under the MIT License unless explicitly stated otherwise in the file header.
