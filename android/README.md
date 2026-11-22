# Glasses Hub for Android

The Android version of Glasses Hub: glanceable apps on RayNeo iO glasses, driven from the phone.

It works the same way as the iPhone app. It doesn't pair with the glasses or sign in to them; it joins
the Bluetooth connection the RayNeo app already has, opens the glasses' caption page and writes text to
it. Open the RayNeo app first, let it connect, then tap **Start the display** in Glasses Hub.

## What's in it

Dashboard, Scoreboard, News, Calendar, Weather, Stocks, Data feeds, Reader (with the teleprompter clock),
Speed read, Message, Movie captions, Live text, Live translate (through Soniox), Guitar chords, Drum
trainer, Metronome, Tuner, Timer, Dice & coin, Walking tour, Planes overhead, Word game, 20 questions,
Trivia host and Odd facts.

Things Android allows that the iPhone doesn't:

- **Phone notifications on the glasses.** With notification access allowed, each notification shows on
  Glasses Hub's page for a few seconds.
- **Clickers and media keys** (next, previous, play/pause) work from any screen of the app.
- **Share to Glasses Hub** from any app puts the shared text on the glasses.

Not in this version: the PC link, Gmail, and translating on the phone itself.

## Layout

- `core/` is everything about what goes on the glasses (wire format, layout, each app's cards), in
  plain Kotlin with no Android in it. `./gradlew :core:test` runs its tests on any computer.
- `app/` is the Android app: Bluetooth, the screens, the microphone, location, the background service.
  `./gradlew :app:testDebugUnitTest` starts the app's model and draws every screen once.

## Building

Pushing to the `android-app` branch builds an APK on GitHub (see `.github/workflows/android.yml`) and
attaches it to a draft release. Test builds are signed with the key in `testing.keystore`, which is in
the repository on purpose so that each build installs over the last. A Play Store release needs its own
private key, set through `ANDROID_KEYSTORE_FILE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD`.
