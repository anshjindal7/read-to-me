# Read To Me

Turn photos of a physical book into an audiobook you can listen to in the car — free, private,
and entirely on your Mac.

1. Photograph your pages with your phone.
2. Drop the photos into **Read To Me**.
3. Check the text, pick a voice, click **Create Audiobook**.
4. AirDrop the `.m4b` file to your iPhone. It opens in Apple Books, remembers your place, and plays over CarPlay or Bluetooth.

No accounts, no subscriptions, no uploads.

- **Reading pages:** Apple's on-device Vision framework, double-checked by **Qwen3-VL** to fix
  misread words and skip headers, footers and page numbers.
- **Voices:** natural **Qwen3-TTS** voices (Ryan, Aiden, Serena, Vivian) with an adjustable reading
  style, or the built-in macOS voices.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how it all fits together.

## Requirements

- An Apple Silicon Mac (M1 or later) for the Qwen features; any Mac on macOS 13+ for the rest
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode isn't needed
- For Qwen: Python 3.10+ and about 9 GB of disk space

## Build

```bash
./build.sh
```

This creates `build/Read To Me.app` (drag it into `/Applications`) and a command-line version,
`build/photo2audiobook`.

## Set up Qwen (once)

Click **Set Up Qwen** in the app, or run:

```bash
scripts/setup_qwen.sh
```

It installs the Python libraries into `~/Library/Application Support/ReadToMe` and downloads the
two models (~8 GB). Safe to run again.

## Tips

- **Take photos in page order.** Pages are sorted by filename (`IMG_0001`, `IMG_0002`, …), which matches the order your phone took them. Two-page spreads work too.
- **Flat, well-lit pages** read best.
- **Check "Skipped … / fixed …"** under the text to see exactly what was removed or corrected.
- **Try the Style box** with Qwen voices — e.g. "Slow and soothing" or "Lively, with feeling for the characters".
- **Timing:** Qwen's page check takes ~15 s per page; Qwen narration takes about half as long as the audio it makes. The Mac stays awake while it works.

## Command-line version

```bash
./build/photo2audiobook ~/Desktop/MyBook --voice ryan --style "Slow and soothing"
```

Reads every photo in the folder and writes `MyBook.txt` and `MyBook.m4b` next to them.
Use `--voice Samantha` (any Mac voice) and `--no-qwen-check` for a fast run without Qwen.

## A note on copyright

This is meant for making personal audio copies of books you own. Please don't share the audiobooks you create.
