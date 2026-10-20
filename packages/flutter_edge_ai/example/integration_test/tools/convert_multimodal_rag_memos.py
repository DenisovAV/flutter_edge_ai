"""Step 2 of the Multimodal RAG screen's sample audio (step 1 is
generate_knowledge_memos.dart, which has Matcha-TTS speak it on macOS):
resample each clip to 16 kHz mono PCM16 — the rate EmbeddingGemma 2's audio
encoder and Gemma 4's audio input work at — with FFmpeg's bit-exact flags:
the memos into example/assets/knowledge/memos/; the meeting's lines
(meeting_NN_<speaker>.wav) are joined, with pauses, into
example/assets/knowledge/meeting.wav, the spoken question to
example/assets/knowledge/question.wav, and where each meeting line starts
and ends goes
to multimodal_rag_meeting_lines.json next to this script (for subtitles and checks:
the app never sees the text).

usage: python3 -I convert_knowledge_memos.py <directory step 1 wrote>
       (needs ffmpeg on PATH)
"""
import json
import os
import subprocess
import sys
import tempfile
import wave

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "knowledge")
OUT = os.path.join(ASSETS, "memos")

BITEXACT = ["-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact"]
LINES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "multimodal_rag_meeting_lines.json")

# The spoken question "Ask by voice" plays (Inflect's voice).
QUESTION = "question_2_B.wav"

RATE = 16000
LEAD_MS, GAP_MS, TAIL_MS = 600, 650, 1200


def to_16k(source, target):
    subprocess.run(
        ["ffmpeg", "-y", "-i", source, "-ar", str(RATE), "-ac", "1", "-c:a", "pcm_s16le", *BITEXACT, target],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def join_meeting(source):
    lines = json.load(open(os.path.join(source, "meeting_lines.json")))
    pcm = bytearray(RATE * 2 * LEAD_MS // 1000)
    timings = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, line in enumerate(lines):
            name = f"meeting_{i + 1:02d}_{line['speaker']}.wav"
            converted = os.path.join(tmp, name)
            to_16k(os.path.join(source, name), converted)
            with wave.open(converted) as w:
                frames = w.readframes(w.getnframes())
            start = len(pcm) // 2 * 1000 // RATE
            pcm += frames
            end = len(pcm) // 2 * 1000 // RATE
            timings.append({**line, "startMs": start, "endMs": end})
            pcm += bytearray(RATE * 2 * (GAP_MS if i + 1 < len(lines) else TAIL_MS) // 1000)
    target = os.path.join(ASSETS, "meeting.wav")
    with wave.open(target, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(pcm))
    with open(LINES, "w") as f:
        json.dump({"durationMs": len(pcm) // 2 * 1000 // RATE, "lines": timings}, f, indent=2)
        f.write("\n")
    for t in timings:
        print(f"  {t['startMs']:>6} {t['endMs']:>6} {t['speaker']} {t['text']}")
    print(f"meeting.wav -> {target} ({len(pcm) // 2 * 1000 // RATE} ms)")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    names = sorted(n for n in os.listdir(source) if n.startswith("memo_") and n.endswith(".wav"))
    for name in names:
        to_16k(os.path.join(source, name), os.path.join(OUT, name))
        print(f"{name} -> {os.path.join(OUT, name)}")
    if os.path.exists(os.path.join(source, "meeting_lines.json")):
        join_meeting(source)
    question = os.path.join(source, QUESTION)
    if os.path.exists(question):
        target = os.path.join(ASSETS, "question.wav")
        to_16k(question, target)
        print(f"{QUESTION} -> {target}")


if __name__ == "__main__":
    main()
