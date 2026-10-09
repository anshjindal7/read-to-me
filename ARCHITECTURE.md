# How Read To Me works

Read To Me turns photos of book pages into an audiobook. It's a pipeline with two halves:
**photos → text**, then **text → audio**. Each half has a fast built-in Apple option and a
slower, better Qwen option, all running on your Mac.

```
                ┌──────────────────────── PHOTOS → TEXT ────────────────────────┐
 page photos ──▶│ Apple Vision ──▶ Qwen check ──▶ header/footer ──▶ paragraphs │──▶ text you can edit
                │ (every line +    (optional:      rules            + join     │
                │  its position)    fix words,                      pages      │
                │                   drop scrap)                                │
                └──────────────────────────────────────────────────────────────┘
                ┌──────────────────────── TEXT → AUDIO ─────────────────────────┐
 text ─────────▶│ Qwen3-TTS (natural)  or  Mac `say` voice (instant)            │──▶ .m4b audiobook
                └──────────────────────────────────────────────────────────────┘
```

## The files

```
Sources/
  Shared/                    used by both the app and the command-line tool
    PageText.swift           photos → clean text (Apple Vision + the rules)
    QwenCheck.swift          compares Apple's reading with Qwen's to fix words / drop scrap
    Qwen.swift               starts the Python helper and reads its progress
    MacVoice.swift           the built-in Mac voices (`say`)
  ReadToMe/                  the Mac app (SwiftUI)
    App.swift                app state + what each button does
    Views.swift              what the window looks like
  photo2audiobook/main.swift the command-line version
Resources/
  readtome_ai.py             Python helper that runs the Qwen models
  Info.plist                 app name, icon, version
scripts/
  setup_qwen.sh              one-time install of Python libraries + models
  make_icon.swift            draws the app icon
build.sh                     compiles everything into ./build
```

## Half 1: photos → text

### Step 1 — Apple Vision reads the photo (`recognizePages`)
Apple's Vision framework (built into macOS, free, offline) finds every line of text. Crucially,
for each line it also returns a **bounding box**: where the line sits on the photo, as fractions
from 0 to 1 with (0, 0) at the *bottom-left*. Everything clever later on uses these positions.

If the photo shows two facing pages, `splitSpread` looks for a vertical gap ("gutter") that almost
no line crosses and splits the lines into a left page and a right page.

### Step 2 — Qwen double-checks (`QwenCheck.swift`, optional)
Apple Vision is fast but sometimes misreads a word ("weatbered") and has no idea what a header
is. So a second reader, **Qwen3-VL** (a vision-language model that looks at the photo), transcribes
the page, skipping headers and page numbers. We then compare the two readings:

1. **Line them up word by word.** `align` finds the longest sequence of words both readers agree on
   (the classic "longest common subsequence" algorithm — the same idea `diff` uses). Agreed words
   act as anchors; the interesting parts are the gaps between anchors where the readers disagree.
2. **Fix words.** In a gap where both readers have the same number of words, each pair is a
   candidate swap. A swap is accepted only if *all three* hold:
   Apple's word is misspelled (checked with the Mac's own spellchecker), Qwen's word is a real
   word, and they look alike (edit-distance similarity ≥ 0.6).
3. **Drop scrap lines.** A line is dropped only if Qwen left (almost) all of it out *and* its
   position says it isn't body text: it's at the top or bottom edge, separated by a big gap, or
   sticking out of the text column.

**Why not just use Qwen's transcription directly?** Language models occasionally skip a line or
"tidy up" wording, and in a book you'd never notice until you heard it. In this design Qwen can
only *point* at problems; the actual text always comes from Apple's reading, changed only in
tightly checked ways. Every change is listed in the app under "Skipped … / fixed …".

### Step 3 — Rules for headers and footers (`stripHeadersAndFooters`)
Even without Qwen, the rules catch most scrap. For the top two and bottom two lines of each page:
- **Page numbers** — digits, roman numerals, "Page 12" — always go.
- **Bigger type** is a real heading ("Chapter One") — always kept.
- **Running headers** — text that appears at the edge of two or more pages (compared letters-only,
  so "12 THE SILENT FOREST" matches "The Silent Forest 13") — go.
- **Isolated lines** — separated from the body by a big gap — go if they look like headers:
  all caps, contain a page number, or are in smaller type.

`PageLayout` measures each page's "normal" body text (line height, line spacing, letter width,
margins). The rules are all "is this line unusual compared to normal?". Font size is measured as
**average letter width** rather than box height, because box height jumps around with tall
letters and descenders (that bug turned a normal line into a "heading" during testing).

### Step 4 — Paragraphs and page joins (`paragraphs(of:)`, `assembleBook`)
- A line indented past the left margin starts a new paragraph.
- A short line ending in `.` `!` `?` etc. ends a paragraph.
- Headings become their own paragraph with a period added, so the narrator pauses after them.
- Words hyphenated across lines are rejoined ("won-" + "derful").
- If a page ends mid-sentence, the next page's first paragraph is glued on.

Paragraphs are separated by blank lines — the voice step uses those for natural pauses.

## Half 2: text → audio

### Qwen3-TTS (natural voices)
`readtome_ai.py speak` splits the text into paragraphs (long ones cut at sentence ends, ~350
characters), has **Qwen3-TTS** read each piece in the chosen voice and style, adds a short pause
after sentences and a longer one after paragraphs, writes a WAV, and converts it to `.m4b` with
macOS's `afconvert`. It produces audio about twice as fast as real time on an M4 Pro.

The **style** box is passed to Qwen as an instruction ("Warm, calm audiobook narration") — Qwen3-TTS
can change its delivery based on a description.

### Mac voices (instant fallback)
`MacVoice.swift` runs macOS's `say` command, which can write straight to `.m4b`.

### Why `.m4b`?
It's the audiobook flavour of `.m4a` (AAC audio). Apple Books treats it as an audiobook: it
remembers your position, and it plays over CarPlay / Bluetooth.

## How Swift talks to Qwen

The Qwen models run in Python using **MLX**, Apple's machine-learning library for Apple Silicon.
Swift doesn't call Python directly; `Qwen.swift` starts `readtome_ai.py` as a separate process
and reads its output line by line. The "protocol" is deliberately tiny:

```
PROGRESS 3 12          → 3 of 12 done (drives the progress bar)
RESULT {"photo": 0, "text": "..."}   → one page's transcription
```

Anything else the Python libraries print goes to stderr, which is kept only to show an error
message if the process fails. A separate process also means a crash in Python can't take the app
down, and the ~8 GB of models are freed from memory as soon as each job finishes.

### Where things are installed
| What | Where | Size |
|---|---|---|
| Python environment (mlx-vlm, mlx-audio) | `~/Library/Application Support/ReadToMe/venv` | ~0.8 GB |
| Helper script | `~/Library/Application Support/ReadToMe/readtome_ai.py` | tiny |
| Qwen3-VL-8B (4-bit) — reads pages | `~/.cache/huggingface/hub` | ~5 GB |
| Qwen3-TTS-1.7B CustomVoice (8-bit) — voice | `~/.cache/huggingface/hub` | ~3 GB |

`scripts/setup_qwen.sh` (also the app's **Set Up Qwen** button) creates all of this. It's safe to
re-run. To uninstall, delete those folders. "4-bit"/"8-bit" means the model's numbers are stored
in compressed form so it fits in memory and runs faster, at a small cost in accuracy.

## The app (SwiftUI)

- `BookModel` (App.swift) is an `ObservableObject`: it holds the state (photos, text, chosen voice,
  current stage). Its `@Published` properties automatically redraw the window when they change.
- `Stage` is the single source of truth for "what's happening now" — idle, setting up, reading,
  recording, finished, failed. `StatusView` just draws whichever stage it is.
- Long jobs run in `Task { ... }` so the window stays responsive. Apple Vision runs in
  `Task.detached` (a background thread); the Qwen cross-check runs on the main thread because the
  Mac spellchecker isn't safe to use from background threads.
- `keepAwake` stops the Mac sleeping during a multi-hour recording.

## Building

`build.sh` uses `swiftc` (the Swift compiler from the free Command Line Tools) instead of Xcode:
it compiles the sources, then assembles a `.app` bundle by hand — an `.app` is just a folder with
`Contents/MacOS/<binary>`, `Contents/Info.plist` and `Contents/Resources/`. The Python helper and
setup script are copied into Resources, and the app is "ad-hoc" signed so macOS will run it.

## Things you might want to change

| To… | Look at |
|---|---|
| Add or rename Qwen voices | `Qwen.voices` in Qwen.swift (speakers: serena, vivian, uncle_fu, ryan, aiden, ono_anna, sohee, eric, dylan) |
| Use a smaller/faster page reader | `VISION_MODEL` in readtome_ai.py (e.g. `Qwen3-VL-4B-Instruct-4bit`) |
| Change how strict word fixes are | the `0.6` similarity threshold in `applyQwenCheck` |
| Change what counts as a header | `isEdgeJunk` in `stripHeadersAndFooters` |
| Change pause lengths | `0.7` / `0.25` seconds in `speak()` in readtome_ai.py |

## Known limits

- Pages are ordered by filename. Retaking a page mid-book gets a later number, so it'll be out of
  order — rename it or remove it in the app.
- Footnotes are read inline wherever they appear.
- Qwen's page check takes ~15 s per page and narration about half the audio's length, so a
  300-page book is a few hours of processing. The Mac stays awake while it works.
- Kokoro (another good open-source voice) is supported by mlx-audio but its text-processing
  dependency doesn't install on Python 3.14 yet, so it isn't offered.
