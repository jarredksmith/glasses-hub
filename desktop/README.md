# Glasses Hub (Windows)

Glasses Hub runs on your PC and sends short notes to your phone as real push notifications. The phone
can show them on smart glasses that mirror notifications, such as the RayNeo iO.

The phone app doesn't have to be open, and the phone can stay locked. Every note is formatted to fit two
short lines on the glasses.

## What it sends

| Plug-in | What you get |
|---|---|
| **NFL scores** | For the teams you follow (Chiefs by default): a reminder before the game, kickoff, every score with the play ("TD KC! Thornton 2-yd pass from Mahomes"), halftime, and the final score with your record. **Score now** gives the live score, or the last result and the next game. |
| **Trivia host** | You host and read each question off your glasses. The answer shows up a little later, or when you tap **Reveal answer**. **Start a round** runs a whole round on timers. |
| **Odd facts** | A surprising fact every hour (you can change this), only during the hours you pick, on topics you choose. **Fact now** sends one right away. |
| **Send** | Type anything and send it. Scripts and other apps on this PC can post to a local address too. |

Questions and facts come from Claude when a key is available. Glasses Hub uses your CallPilot key on
this PC automatically. Without a key, trivia comes from the free Open Trivia Database and facts come from
Wikipedia's "On this day".

## Setup (once)

1. Double-click **setup.bat**. It installs what it needs (about a minute) and adds a **Glasses Hub**
   shortcut to your desktop.
2. On your iPhone, open **https://jarredksmith.github.io/glasses-hub/** in Safari. Tap **Share →
   Add to Home Screen**, then open **Glasses Hub** from the Home Screen.
3. Type the pairing code the PC shows and tap **Pair and turn on notifications**. Allow notifications
   when iOS asks. A "Glasses Hub is connected" notification confirms it worked.

After that, notes keep arriving with the phone app closed. In iPhone **Settings → Notifications →
Glasses Hub**, keep **Immediate Delivery** on, and allow it in any Focus modes you use.

## Using it

- **Plug-ins tab:** turn each one on or off, change its settings, and use its buttons. The same buttons
  and switches are on the phone, so you can run trivia from the couch.
- **Quiet hours** (Settings tab, 10 PM to 7 AM by default) hold back automatic notes. Things you ask for
  always come through. Game alerts can come through too; that's set in the NFL settings and on by default.
- **Start Glasses Hub when I sign in to Windows** keeps it running in the background.
- **New code** makes a new pairing code. Every phone then has to pair again.

### Sending from scripts

The Send tab shows a private address on this PC with a key in it. For example, in PowerShell:

```powershell
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8770/send?key=YOURKEY' -Body @{title='Render done'; body='Explainer video exported'}
```

Only this PC can reach the address.

## How it works

- **Pairing:** the phone and PC exchange setup messages through a public relay (ntfy.sh). The messages are
  encrypted with a key made from the pairing code, so the relay only sees scrambled data.
- **Notes:** each note goes by standard Web Push, straight from this PC to Apple's push service. It is
  encrypted for your phone and signed with a key that never leaves this PC. No server of ours is involved.
- **Your data:** settings, keys and the log are stored in `%LOCALAPPDATA%\GlassesHub`, outside OneDrive.

## Troubleshooting

- **No notification after pairing:** check that notifications are allowed for Glasses Hub in iPhone
  Settings, then open the phone app and tap **Turn on notifications**.
- **The phone list says "relay only":** that phone can't receive push notifications. It's usually not
  opened from the Home Screen, so it only gets notes while the app is open.
- **Something else:** the log is at `%LOCALAPPDATA%\GlassesHub\glasses-hub.log`.
