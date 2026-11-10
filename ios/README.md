# Glasses Hub for iPhone

A native iPhone app that uses your RayNeo iO glasses as a live text screen, not only a place where
notifications pop up.

## How the display works

The glasses have a Live Captions page that shows five to seven lines of text and replaces them in place.
Glasses Hub opens that page and writes its own text to it. It does this over the Bluetooth connection the
RayNeo app already holds; iOS lets apps share one.

- **Needs:** the RayNeo app connected to your glasses. Stock firmware. Nothing is installed on the glasses.
- **Doesn't do:** pairing, the RayNeo sign-in handshake, settings changes, or taking the screen from
  something else that's open. It only ever closes the page it opened.
- **On the glasses:** turn the crown to scroll long text. Hold the crown to leave.
- **Fallback:** when the display is off, alerts go out as ordinary notifications, which the RayNeo app
  mirrors to the glasses.

The approach was proven on hardware by the GlanceBoard project. The layout numbers (20 double-width
characters by 5 lines at the large size, 26 by 7 at the small size) come from the OpenRayneo project's
published measurements.

## What's in it

| App | What the glasses show |
|---|---|
| Dashboard | Time and date, plus a line each for your team's score, the weather and your next event |
| Scoreboard | Live score, clock, down and distance, last play. NFL, NBA, MLB, NHL, college football and basketball |
| Trivia host | The question, then the answer, on timers or when you tap |
| Odd facts | A new fact every few minutes |
| Timer | A countdown with a progress bar |
| Weather | Now, today and tomorrow for a city you pick |
| Calendar | What's left on today's calendar |
| Reader | Any text you paste, scrolled with the crown |
| Message | A line of text that stays up |

Scores, a finished timer and notes from the PC interrupt whatever is showing for a few seconds.

## The PC

The PC tab pairs with Glasses Hub for Windows using the same code as the web app. The PC's notes then
show up as cards on the glasses, and its plug-ins can be switched and run from the phone.

While the app is running (in front, or in the background with the display on) notes come over the relay
and show on the glasses' display. When it isn't, the PC sends them by Apple push and they arrive as
notifications. The app tells the PC which case applies every 45 seconds.

Apple push needs a key on the PC: an "Apple Push Notifications service" key (.p8) from the Apple Developer
account, chosen once under Settings in the PC app. Without it, notes only arrive while the app is running.

## Code

- `HubCore/` is a plain Swift package: the wire format, the display session, text layout and each app's
  logic. No iPhone needed: `cd HubCore && swift test`.
- `App/` is the SwiftUI app: the Bluetooth link, the once-a-second loop, the screens.
- `project.yml` is turned into an Xcode project by XcodeGen during the build.

## Building

`.github/workflows/ios.yml` runs on every push that touches `ios/`. It tests HubCore, builds the app and
uploads it to TestFlight. Uploading needs three repository secrets, the same ones CallPilot uses:
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`. Without them it stops after checking that the app compiles.

## Not yet tested on glasses

The wire format and session rules are unit-tested, and the app compiles. What only hardware can show:
how many characters fit a line at each size (there's a test card and a setting for it), whether a screen
that isn't changing stays lit, and how long the battery lasts with the display on for hours.
