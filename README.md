# PadProbe

Diagnostic tool to find out how a **Bluetooth controller** talks to an **old iPad (iOS 8, jailbreak)** through [BTstack](https://github.com/bluekitchen/btstack).

The app searches for devices, connects to the controller (HID over L2CAP) and shows the raw reports in hex. You mark the "idle" state and press one button at a time, and it highlights which bytes and bits changed. That's how the 8BitDo Pro 2's format was mapped for [MD16](https://github.com/douugr/md16) and [SNES16](https://github.com/douugr/snes16).

## Install

Add the Cydia repository **https://douugr.github.io/repo/** (Cydia or Melder → Sources → Edit → Add) and install **PadProbe**. The BTstack package is installed with it.

## Requirements (to build)

- Jailbroken iPad on iOS 8 with OpenSSH and the **BTstack** package (`ch.ringwald.btstack` 1.1)
- Mac with Xcode 13.4.1 extracted (armv7 toolchain) and `ldid`

## Build and install

```bash
export X13=/path/to/Xcode-13.4.1.app/Contents/Developer
./build.sh install
```

The app is installed in `/Applications`, outside the sandbox, so it can talk to BTdaemon. `libBTstack.dylib` is copied from the iPad itself and is not versioned.

Before using it, turn iOS Bluetooth off in Settings. The "Save log" button writes the log to `Documents/padprobe.txt`.

## License

The headers in `vendor/btstack` are from BTstack (© BlueKitchen GmbH / Matthias Ringwald) and follow its license.
