# footsie

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Footsie BLE app

This app connects to the Footsie device over BLE and allows adjusting the `gamma` parameter.

Permissions
- Android: the app requires `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and `ACCESS_FINE_LOCATION` (for older Android versions).
- iOS: the app requires Bluetooth usage description keys in `Info.plist` (already added).

Run on device
```bash
flutter pub get
flutter run
```

Notes
- The app scans for a device named `Footsie` or advertising the Footsie service UUID.
- Gamma is read/written as a 2-byte unsigned integer representing gamma × 100 (e.g. `220` = 2.20).
- You may need to grant runtime permissions on Android 12+ when prompted.

If you want, I can add runtime permission prompts to the app so it requests the required permissions automatically.
