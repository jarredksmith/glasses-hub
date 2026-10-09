# Glasses Hub

**Glasses Hub sends sports scores, trivia questions and odd facts from your PC to your phone as push
notifications. Smart glasses that mirror phone notifications (like the RayNeo iO) show them.**

The phone app doesn't need to stay open. Notes arrive even when it's closed and the phone is locked.

- **Phone app:** https://jarredksmith.github.io/glasses-hub/
  - Open it in Safari on an iPhone.
  - Add it to your Home Screen.
  - Open it from there.
- **PC app (Windows):** the [`desktop`](desktop) folder.
  - Download it.
  - Run `setup.bat`.
  - Type the pairing code it shows into the phone app.

## What's in it

- **NFL scores:**
  - Your teams' kickoff, every score with the play, halftime and the final.
  - A "Score now" button.
- **Trivia host:**
  - You read the question off your glasses, and everyone else guesses.
  - The answer appears on a timer or when you tap.
- **Odd facts:**
  - A surprising fact every so often, on topics you pick, during hours you pick.
- **Send:**
  - Push any text, from the PC or from your own scripts, through a local address.

Every note is cut to fit two 70-character lines, because that's what the RayNeo iO shows. You can change
the widths in the phone app.

## Privacy

There is no account and no server of ours:

- **Pairing:** the PC and phone pair through an encrypted relay (ntfy.sh).
- **Notes:** they travel by standard Web Push, end-to-end encrypted, straight from your PC to Apple's push
  service.
- **Storage:** settings and keys are stored only on your PC and phone.

Facts and trivia can come from Claude, using your own API key. Without a key, they come from Wikipedia
and the Open Trivia Database.

Requires iOS 16.4 or later. iOS 18.4 or later is recommended for the most reliable delivery.
