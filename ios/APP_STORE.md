# Nocturnal for iPhone: App Store notes

**What it is.** The companion to Nocturnal on a Mac or PC. It shows whether the computer keeps working with the lid
shut, what its AI agents are doing, and its battery, and lets you switch Off / When Busy / Always, wake it or let it
sleep. It pairs with one computer by scanning the QR code Nocturnal shows there.

**For App Review.** No account and no login. Tap **Try the demo** on the first screen: a pretend computer inside the
app answers every control, with nothing sent anywhere. Leave it from Settings › Leave the demo.

**Privacy (App Store Connect answers).**
- Data collected: none. No analytics, no tracking, no third-party SDKs.
- The only network traffic is to the relay (ntfy.sh, or the user's own) and is end-to-end encrypted with AES-256-GCM;
  the relay sees only sealed text. The key stays in the Keychain (this device only, not in backups).
- The phone sends its generic device name ("iPhone") to the paired computer so it can be listed there.
- Camera: only to scan the pairing QR code (`NSCameraUsageDescription`). Nothing is recorded or kept.
- Privacy manifest: `NocturnalPhone/PrivacyInfo.xcprivacy` (UserDefaults, reason CA92.1: the last status shown).
- Privacy policy URL: https://nocturnal.tools/privacy

**Encryption.** Uses only Apple's CryptoKit (AES-GCM, SHA-256) to protect the user's own messages, so
`ITSAppUsesNonExemptEncryption` is `NO`. Confirm in App Store Connect when submitting.

**Checklist before submitting.**
1. Set your team in Signing & Capabilities (no team is set in the repo).
2. Screenshots: the UI test `testDemoWalkthrough` saves the home, Always, Off and Settings screens of the demo.
3. Category: Utilities. Age rating: 4+. iPhone only, portrait, iOS 26 or later.
