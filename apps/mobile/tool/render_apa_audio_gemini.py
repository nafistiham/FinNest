#!/usr/bin/env python3
"""Render the bundled FinNest Assistant clips with Gemini 3.8 TTS.

The five fixed lines (byte-for-byte `lib/features/intervention/logic/asset_catalog.dart`
`AssetCatalog.scripts`, mirroring risk-mw `intervene.py`) are spoken by the same engine, voice and
delivery as the live lines: model `gemini-3.8-flash-lite-tts` on Vertex (`global`), voice Sulafat,
language bn-BD, the expressive Bangladeshi delivery from `FnaVoiceStyle.urgentStyle` sent as the
text part's `speechMetadata.style`. So a fallback clip sounds like the live voice and the
assistant never speaks in the phone's own voice.

Pipeline per line: generateContent (AUDIO) -> 24 kHz mono 16-bit PCM -> ffmpeg -> OGG/Opus
48 kHz mono 32 kbps -> assets/audio/<id>.ogg, then the durations are printed for
`AssetCatalog.durationMs`.

Needs: gcloud authenticated as a member of the Google Cloud project
(`gcloud auth print-access-token`), the Vertex AI API enabled, ffmpeg, ffprobe. No API key:
the call carries the user's access token and the quota project header.
Cost: five short lines, a few cents.

The Google Cloud project comes from `--project` or the `GOOGLE_CLOUD_PROJECT` environment
variable. There is no default.

usage: GOOGLE_CLOUD_PROJECT=my-project tool/render_apa_audio_gemini.py [--out assets/audio] [--only ID ...]
"""
import argparse
import base64
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

MODEL = "gemini-3.8-flash-lite-tts"
VOICE = "Sulafat"
LANGUAGE = "bn-BD"
# == FnaVoiceStyle.urgentStyle in lib/features/intervention/logic/gemini_tts.dart
STYLE = (
    "Speak in Bangladeshi Bengali with the natural Dhaka accent and pronunciation, as a "
    "trustworthy, professional, empathetic and helpful financial customer-care agent speaking to "
    "a customer: soft-spoken, low-key and unhurried, in an even, level tone at a slow, steady pace, "
    "like a bank call-centre agent calmly reading a notice. Composed and reassuring, with only "
    "gentle emphasis on the key words; no urgency, no drama, no raised voice, never excited, "
    "intense, emotional, over-familiar or panicked"
)
# == AssetCatalog.scripts
LINES = {
    "apa_hold_call_active": "আমি ফিননেস্ট সহকারী বলছি। আপনি এখন কলে আছেন। কলে থাকা অবস্থায় পিন বদলানো বা কোড বলা নিরাপদ নয়। আমি এটা এক ঘণ্টার জন্য আটকে রাখলাম। আপনার আপনজন কাউকে দিয়ে যাচাই করিয়ে নিন।",
    "apa_hold_screen_share": "আপনার স্ক্রিন এখন অন্য কেউ দেখছে। আগে স্ক্রিন শেয়ার বন্ধ করুন, তারপর আবার চেষ্টা করুন।",
    "apa_delay_new_payee": "এই নম্বরে আপনি আগে কখনো টাকা পাঠাননি, আর অঙ্কটাও বড়। এক ঘণ্টা পরে পাঠানো যাবে। চাইলে আপনার আপনজনকে দিয়ে এখনই অনুমোদন করাতে পারেন।",
    "apa_generic_caution": "আমি ফিননেস্ট সহকারী বলছি। একটু থামুন। এই লেনদেনটি নিয়ে আমার কিছু সন্দেহ আছে, চলুন একবার যাচাই করি।",
    "apa_text_default": "আমি ফিননেস্ট সহকারী বলছি। আপনি যা করতে চাইছেন তা আমি দেখছি। কেউ যদি ফোনে কোড বা পিন চায়, কখনো দেবেন না। বলুন, কী সাহায্য করতে পারি?",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default=os.environ.get("GOOGLE_CLOUD_PROJECT", ""),
                    help="Google Cloud project id (default: $GOOGLE_CLOUD_PROJECT)")
    ap.add_argument("--out", default=str(pathlib.Path(__file__).resolve().parent.parent / "assets" / "audio"))
    ap.add_argument("--only", nargs="*", default=None)
    args = ap.parse_args()
    if not args.project:
        print("no project: pass --project or set GOOGLE_CLOUD_PROJECT", file=sys.stderr)
        return 2
    token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
    url = f"https://aiplatform.googleapis.com/v1/projects/{args.project}/locations/global/publishers/google/models/{MODEL}:generateContent"
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for aid, text in LINES.items():
        if args.only and aid not in args.only:
            continue
        body = {
            "contents": [{"role": "user", "parts": [{"text": text, "speechMetadata": {"style": STYLE}}]}],
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {"languageCode": LANGUAGE, "voiceConfig": {"prebuiltVoiceConfig": {"voiceName": VOICE}}},
            },
        }
        req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={
            "Authorization": "Bearer " + token, "Content-Type": "application/json", "x-goog-user-project": args.project})
        started = time.time()
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            print(aid, "HTTP", e.code, e.read()[:300].decode(errors="replace"), file=sys.stderr)
            return 1
        parts = d["candidates"][0]["content"]["parts"]
        inline = [p for p in parts if "inlineData" in p]
        if not inline:
            print(aid, "no audio part", file=sys.stderr)
            return 1
        mime = inline[0]["inlineData"]["mimeType"]
        raw = base64.b64decode(inline[0]["inlineData"]["data"])
        pcm = out / f"{aid}.pcm"
        pcm.write_bytes(raw)
        ogg = out / f"{aid}.ogg"
        rate = "24000"
        if "rate=" in mime:
            rate = mime.split("rate=")[1].split(";")[0]
        subprocess.check_call(["ffmpeg", "-loglevel", "error", "-y", "-f", "s16le", "-ar", rate, "-ac", "1", "-i", str(pcm),
                               "-c:a", "libopus", "-ar", "48000", "-ac", "1", "-b:a", "32k", str(ogg)])
        pcm.unlink()
        dur = subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(ogg)], text=True).strip()
        print(f"{aid}: {len(raw)} bytes PCM in {time.time() - started:.1f} s -> {ogg.name}, {int(float(dur) * 1000)} ms")
    print("now update AssetCatalog.durationMs with the printed milliseconds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
