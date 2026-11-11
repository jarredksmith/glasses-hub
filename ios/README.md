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
- **On the glasses:** hold the crown to leave.
- **Fallback:** when the display is off, alerts go out as ordinary notifications, which the RayNeo app
  mirrors to the glasses.

The approach was proven on hardware by the GlanceBoard project. The layout numbers (20 double-width
characters by 5 lines at the large size, 26 by 7 at the small size) come from the OpenRayneo project's
published measurements.

## What's in it

| App | What the glasses show |
|---|---|
| Dashboard | Time and date, plus a line each for your team's score, the weather, your next event and the top headline |
| Scoreboard | One game (score, clock, who has the ball, last play), its box score as a table by period, or every game in your leagues as a table. NFL, college football, NBA, WNBA, college basketball, MLB, NHL, MLS, Premier League |
| News | Headlines from feeds you pick, turning by themselves; any story in full, a page at a time |
| Mail | Your Gmail inbox, read-only: sender, subject and preview for each message, and the full text a page at a time |
| Trivia host | The question, then the answer, on timers or when you tap |
| Odd facts | A new fact every few minutes |
| Timer | A countdown with a progress bar |
| Weather | Now; the next 12 hours as a table; the week ahead |
| Calendar | Today's events with now/next markers, or the month as a grid with today marked |
| Reader | Any text you paste, a page at a time |
| Message | A line of text that stays up |

Scores (per sport), a finished timer and notes from the PC interrupt whatever is showing for a few seconds.

## Pop-up mode

With "Pop up only when something comes in" on, the display stays closed. When a score, a finished timer,
a PC note or a scheduled fact arrives, the app opens the display, shows it for a few seconds and closes it
again. The app has to be running in the background for this (it keeps itself awake the same way it does
with the display on). If the display can't open, the alert goes out as a notification instead.

## Formatting

- **Tables that line up.** The glasses' ordinary letters vary in width, but double-width characters are
  all one size and two ordinary digits fill one of them. `Grid` builds every table from those.
- **Symbols.** Dots, stars, arrows, squares and box lines from the old GB2312 set, which a Chinese-market
  display font should carry. Settings has three levels (plain, symbols, symbols plus shaded bars) and a
  test that puts every character used on the glasses.
- **The crown navigates.** The glasses' usage reports reach the phone about a second after a crown turn
  or click (seen on Strix OS 1.0.6.11); they don't say which way the crown turned. So a turn is "next"
  (page, headline, game, event, message) and a click is "select": open what's showing, go back if
  something is open, otherwise bring up the on-glasses menu of apps. Lists end in a stop that also leads
  to the menu.
- **Buttons turn pages.** With the display on, the phone's volume buttons (or a Bluetooth ring that sends
  them) step pages forward and back, even with the phone locked. The volume is put back after each press.
- **Teleprompter hand-off.** "Send to teleprompter" saves the text as a .txt file in this app's folder
  (Files > On My iPhone > Glasses Hub) and opens the share sheet. The RayNeo app's teleprompter imports
  it, and there the crown scrolls and stays put. Sending straight into the teleprompter isn't possible
  from an iPhone app: that transfer runs over classic Bluetooth, which iOS doesn't open to apps.
- **Pages, not scrolling.** The caption page jumps back to the end of scrolled text after a few seconds,
  so anything taller than the screen is split into pages that turn on a timer, with pause and step
  buttons on the phone. Sending long text marked "finished" so the crown can scroll it is an experiment
  behind a switch.

## The PC

The PC tab pairs with Glasses Hub for Windows using the same code as the web app. The PC's notes then
show up as cards on the glasses, and its plug-ins can be switched and run from the phone.

While the app is running (in front, or in the background with the display on) notes come over the relay
and show on the glasses' display. When it isn't, the PC sends them by Apple push and they arrive as
notifications. The app tells the PC which case applies every 45 seconds.

Apple push needs a key on the PC: an "Apple Push Notifications service" key (.p8) from the Apple Developer
account, chosen once under Settings in the PC app. Without it, notes only arrive while the app is running.

## Gmail

Mail uses Google's API with read-only permission, signed in on Google's own page. It needs a Google
"OAuth client ID" of the iOS kind for bundle ID `com.jarredsmith.glasseshub`, from a Google Cloud project
with the Gmail API turned on; paste it under Apps > Mail. The sign-in key lives in the iPhone's Keychain.

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
