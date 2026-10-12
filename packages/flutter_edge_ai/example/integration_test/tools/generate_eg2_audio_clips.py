"""The EmbeddingGemma 2 audio test clips (R5 §10.4), synthesized here — no
recordings, so nothing to license. Speech comes from eSpeak NG 1.52.0 (formant
synthesis: no recorded voice is involved), conversions from FFmpeg 9.0.2 with
bit-exact flags, so a rerun with the same two versions writes the same bytes
(the M4A and Ogg clips excepted: they only have to be refused in Dart).

Not macOS `say`: the macOS licence allows its system voices' output for
personal, non-commercial use only, which a public repository is not.

Writes into example/assets/eg2_audio/ (Flutter assets, so the device suites
can read them on a phone):
- <name>.wav                 six spoken sentences, 16 kHz mono PCM16 — the
                             rate and layout the engine works at
- kitchen_lights_44k_stereo.wav  the first sentence at 44.1 kHz stereo: the
                             engine mixes down and resamples (miniaudio)
- kitchen_lights.mp3         the same, MP3 (LAME, 48 kbit/s)
- kitchen_lights.flac        the same, FLAC (lossless)
- kitchen_lights.m4a         the same, AAC in MP4 (macOS `afconvert`), and
- kitchen_lights.ogg         Opus in Ogg: two containers miniaudio does not
                             open, so the pass leaves them out and core refuses
                             them on the caller's isolate
- corrupt_riff.wav           a RIFF/WAVE header over bytes that are not
                             audio: passes the sniff, fails in the engine

The sentences, and the text queries the device suites ask for each one, are
SPEECH below; the golden (eg2_audio_golden.py) records both.

usage: python3 -I generate_eg2_audio_clips.py
       (needs espeak-ng 1.52.0 and ffmpeg 9.0.2 with libmp3lame and libopus
       on PATH; macOS for afconvert)
"""
import os
import subprocess
import tempfile

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "eg2_audio")

# (name, what is said, the text query a device suite asks for it)
SPEECH = [
    ("kitchen_lights", "Please turn off the lights in the kitchen.", "turn off the kitchen lights"),
    ("weather_paris", "What will the weather be like in Paris tomorrow?", "the weather in Paris tomorrow"),
    ("table_for_two", "I would like to book a table for two at seven tonight.", "book a dinner table for two"),
    ("flight_delayed", "My flight to Tokyo has been delayed by three hours.", "my flight to Tokyo is delayed"),
    ("doctor_appointment", "I need to see a doctor about my sore throat.", "a doctor for a sore throat"),
    ("piano_lesson", "Her piano lesson starts at four on Thursday.", "a piano lesson on Thursday"),
]

BITEXACT = ["-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact"]


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ffmpeg(src, dst, *args):
    run(["ffmpeg", "-y", "-i", src, *args, *BITEXACT, dst])


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        raw = {}
        for name, said, _ in SPEECH:
            # eSpeak NG writes 22.05 kHz mono; 150 words per minute.
            raw[name] = os.path.join(tmp, f"{name}.wav")
            run(["espeak-ng", "-v", "en-us", "-s", "150", "-w", raw[name], said])
            ffmpeg(raw[name], os.path.join(OUT, f"{name}.wav"), "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le")

        source = raw["kitchen_lights"]
        ffmpeg(source, os.path.join(OUT, "kitchen_lights_44k_stereo.wav"),
               "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le")
        ffmpeg(source, os.path.join(OUT, "kitchen_lights.mp3"),
               "-ar", "16000", "-ac", "1", "-c:a", "libmp3lame", "-b:a", "48k")
        ffmpeg(source, os.path.join(OUT, "kitchen_lights.flac"), "-ar", "16000", "-ac", "1", "-c:a", "flac")
        ffmpeg(source, os.path.join(OUT, "kitchen_lights.ogg"), "-c:a", "libopus", "-b:a", "24k")
        m4a = os.path.join(OUT, "kitchen_lights.m4a")
        if os.path.exists(m4a):
            os.remove(m4a)
        run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "32000", source, m4a])

    # The first 12 bytes of a real WAV (RIFF, size, WAVE), then 4 KiB that are
    # not a fmt/data chunk: miniaudio fails to open it (measured: status 2).
    with open(os.path.join(OUT, "kitchen_lights.wav"), "rb") as f:
        head = f.read(12)
    with open(os.path.join(OUT, "corrupt_riff.wav"), "wb") as f:
        f.write(head + bytes(range(256)) * 16)


if __name__ == "__main__":
    main()
