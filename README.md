# Read To Me

Turn photos of a physical book into an audiobook you can listen to in the car — free, and entirely on your Mac.

1. Photograph your pages with your phone.
2. Drop the photos into **Read To Me**.
3. Check the text, pick a voice, click **Create Audiobook**.
4. AirDrop the `.m4b` file to your iPhone. It opens in Apple Books, remembers your place, and plays over CarPlay or Bluetooth.

No accounts, no subscriptions, no uploads. Text is read with Apple's on-device Vision framework and spoken with the built-in macOS voices.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode isn't needed

## Build

```bash
./build.sh
```

This creates `build/Read To Me.app` (drag it into `/Applications`) and a command-line version, `build/photo2audiobook`.

## Tips

- **Take photos in page order.** Pages are sorted by filename (`IMG_0001`, `IMG_0002`, …), which matches the order your phone took them.
- **Flat, well-lit pages** read best. Words curving into the spine are the most likely to be misread — fix them in the text box before recording.
- **Get a better voice for free:** System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, and download a voice marked *Premium* (e.g. "Ava (Premium)" or "Zoe (Premium)"). Click ↻ next to the voice menu to see it.

## Command-line version

```bash
./build/photo2audiobook ~/Desktop/MyBook --voice "Ava (Premium)" --rate 190
```

Reads every photo in the folder and writes `MyBook.txt` and `MyBook.m4b` next to them.

## Project layout

```
Sources/ReadToMe/ReadToMe.swift               SwiftUI app
Sources/photo2audiobook/photo2audiobook.swift  command-line tool
Resources/Info.plist                          app bundle metadata
scripts/make_icon.swift                       draws the app icon
build.sh                                      builds everything into ./build
```

## A note on copyright

This is meant for making personal audio copies of books you own. Please don't share the audiobooks you create.
