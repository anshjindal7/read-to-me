"""Qwen helpers for Read To Me, run locally on Apple Silicon with MLX.

  transcribe  Qwen3-VL reads each page photo, skipping headers, footers and page numbers.
              The app compares this with Apple Vision's text to catch scrap lines and misread words.
  speak  Qwen3-TTS narrates a text file into an .m4b audiobook.

Both print "PROGRESS <done> <total>" lines so the app can show progress.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

VISION_MODEL = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
VOICE_MODEL = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"

TRANSCRIBE_PROMPT = """Transcribe the main text of this book page exactly as printed, word for word.
Skip running headers (the book or chapter title repeated at the top), page numbers, footers, and any text from a neighbouring page.
Keep chapter titles and section headings. Do not add, summarise, rephrase or modernise anything.
Output only the transcription."""


def progress(done, total):
    print(f"PROGRESS {done} {total}", flush=True)


def transcribe(job_path):
    """Job: a JSON list of photo paths. Prints one RESULT line per photo with Qwen's transcription."""
    from PIL import Image, ImageOps
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template

    with open(job_path) as f:
        photos = json.load(f)
    model, processor = load(VISION_MODEL)
    prompt = apply_chat_template(processor, model.config, TRANSCRIBE_PROMPT, num_images=1)
    progress(0, len(photos))

    for i, photo in enumerate(photos):
        # Upright and smaller = much faster, and still plenty sharp for printed text.
        image = ImageOps.exif_transpose(Image.open(photo)).convert("RGB")
        image.thumbnail((1400, 1400))
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
            image.save(tmp.name, quality=92)
            text = generate(model, processor, prompt, image=[tmp.name], max_tokens=2500, temperature=0.0).text
        os.unlink(tmp.name)
        print("RESULT " + json.dumps({"photo": i, "text": text.strip()}), flush=True)
        progress(i + 1, len(photos))


def split_for_speech(text, limit=350):
    """Paragraphs, with long ones cut at sentence ends so each piece stays manageable."""
    pieces = []
    for paragraph in re.split(r"\n\s*\n", text):
        paragraph = " ".join(paragraph.split())
        if not paragraph:
            continue
        # Split after . ! ? … — or after one of those followed by a closing quote or bracket.
        sentences = re.split(r"(?:(?<=[.!?…])|(?<=[.!?…][\"”’)]))\s+", paragraph)
        chunk = ""
        for sentence in sentences:
            if chunk and len(chunk) + len(sentence) > limit:
                pieces.append((chunk, False))
                chunk = sentence
            else:
                chunk = f"{chunk} {sentence}".strip()
        if chunk:
            pieces.append((chunk, True))  # True = end of paragraph
    return pieces


def speak(text_path, voice, style, out_path):
    import numpy as np
    import soundfile as sf
    from mlx_audio.tts.utils import load_model

    with open(text_path) as f:
        pieces = split_for_speech(f.read())
    model = load_model(VOICE_MODEL)
    rate = model.sample_rate
    progress(0, len(pieces))

    wav_path = out_path + ".wav"
    with sf.SoundFile(wav_path, "w", samplerate=rate, channels=1) as wav:
        for i, (piece, paragraph_end) in enumerate(pieces):
            results = model.generate(text=piece, voice=voice, instruct=style or None, lang_code="english")
            for result in results:
                wav.write(np.array(result.audio).reshape(-1))
            wav.write(np.zeros(int(rate * (0.7 if paragraph_end else 0.25)), dtype=np.float32))
            progress(i + 1, len(pieces))

    subprocess.run(["afconvert", "-f", "m4bf", "-d", "aac", "-b", "64000", wav_path, out_path], check=True)
    os.unlink(wav_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    t = sub.add_parser("transcribe")
    t.add_argument("job")
    s = sub.add_parser("speak")
    s.add_argument("text")
    s.add_argument("out")
    s.add_argument("--voice", default="ryan")
    s.add_argument("--style", default="Warm, calm audiobook narration.")
    args = parser.parse_args()

    if args.command == "transcribe":
        transcribe(args.job)
    else:
        speak(args.text, args.voice, args.style, args.out)
