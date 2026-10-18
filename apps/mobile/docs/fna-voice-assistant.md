# FinNest Assistant: architecture

FinNest Assistant (FNA, ফিননেস্ট সহকারী) answers phone and mobile-money safety questions in Bangla
and English. It opens as a chat. Voice mode is one tap away. This note describes how the app builds it.

## Rules

- FNA never moves, releases or approves money.
- FNA never explains in its own words why money was held. Only the server's reason text is shown
  (rule FR-3, see "Server-only hold reasons").
- FNA never asks for, repeats or reads back a PIN, OTP or code.
- FNA names no private company other than FinNest. Public agencies (Bangladesh Bank, BTRC, Bangladesh
  Police and 999, CID, BFIU, the Election Commission) and their public lines are allowed. The knowledge
  base and the test datasets follow the same rule.
- The microphone is open only while voice mode is on screen. Transcripts and audio are never logged.

## Experience

- The Home bar shows "Ask FNA". It opens the chat: transcript, topic chips, a text field and a large
  "Talk" button. Each answer has "Hear it".
- Chips and typed questions go to the text agent.
- "Talk" opens voice mode. A short microphone explanation appears before the Android permission
  dialog. FNA greets, then listens. Captions show both sides. Controls: Stop, Type instead, End.
- Voice mode closes after 30 s of silence, on End, after 10 minutes, or when the app goes to the
  background.
- A permanent strip says: "Do not say your PIN or any code out loud, not even to FNA."
- After a flagged call, a call summary card shows the time, what the caller asked for, the caller's
  words, what to do now and how to prevent it next time. It works offline.

## Models and services

| Path | Model and region | Transport |
|---|---|---|
| Voice mode | Gemini Live, `gemini-3.8-live`, `us-central1` | Firebase AI Logic (`firebase_ai`) on Vertex AI |
| Chat (text agent) | `gemini-3.8-flash`, fallback `gemini-3.5-flash-lite`, `global` | Firebase AI Logic on Vertex AI |
| Spoken lines | Gemini TTS (`gemini-3.8-flash-lite-tts`), `global` | Firebase AI Logic on Vertex AI |
| Scam check | risk-mw `POST /v1/scam/turn` | HTTPS |

There is no API key in the app. Firebase AI Logic calls carry limited-use App Check tokens
(`lib/features/apa/voice/fna_ai_client.dart`). Without Firebase, the chat falls back to the offline
guide and voice mode is not offered.

Fallback order: voice mode (Live), then chat (text agent), then the offline guide (the top knowledge
chunk, read by the phone's TTS).

Text agent settings (in code): thinking budget 0, and 20 s for the whole answer. The first model gets
14 s; the fallback model gets the rest.

## Components

| Part | File | Job |
|---|---|---|
| ApaController | `lib/features/apa/logic/apa_controller.dart` | Front door of the sheet: transcript, held line, chips, scam check. Folds voice events into bubbles. |
| FnaVoiceSession | `lib/features/apa/voice/fna_voice_session.dart` | Pure Dart state machine. Transport, microphone, player, tools and clock are injected. |
| FnaLiveTransport | `lib/features/apa/voice/fna_live_transport.dart` | Wraps the Live session. Emits events, waits for setup, resumes with a new connection. |
| FnaTextAgent | `lib/features/apa/voice/fna_text_agent.dart` | Chat answers: model chain, history, guard, timeout. |
| FnaTools | `lib/features/apa/voice/fna_tools.dart` | One registry of five tools, shared by voice and chat. |
| Transcript guard | `lib/features/apa/voice/fna_transcript_guard.dart` | Checks both transcripts and every answer. |
| Knowledge | `lib/features/apa/knowledge/`, `assets/fna_kb/safety_kb.v1.json` | Normaliser, index, loader. |
| Audio | `lib/features/apa/voice/native_fna_audio.dart`, `android/.../VoiceAudioSession.kt`, `PcmPlayer.kt` | Communication audio mode with the loudspeaker, PCM playback, drain signal. |

Tools:

- `search_safety_knowledge(query)`: on-device search of the knowledge base.
- `get_my_safety_status()`: the last App Safety Check verdict.
- `get_fraud_call_summary()`: the flagged call, for the summary card.
- `check_caller_words(text)`: sends a caller's words to `POST /v1/scam/turn`.
- `show_hold_reason()`: the app shows and speaks the server's reason text. The model gets only
  `{shown: true}`.

## On-device knowledge search (BM25)

The knowledge base is a bundled JSON asset of about 80 chunks in Bangla and English. Each chunk has
titles, text, tags, synonyms and a public source. The index scores BM25 over folded words and
character trigrams, so spelling variants and Bangla case endings still match. A search takes under
1 ms; no embeddings and no network call are needed. A retrieval eval of 25 questions runs as a unit
test (`test/features/apa/knowledge/safety_kb_eval_test.dart`), and a schema test checks that the
asset names no private business and no number but the helpline and public lines.

## Transcript guard

The guard runs on the customer's transcript, on FNA's transcript as it streams, and on every chat
answer. It blocks:

- a code-like number (PIN, OTP) said by the customer, and any request for a PIN, OTP, password or
  code by FNA;
- wording that tells the customer to send, release, approve, retry or continue a payment;
- FNA's own explanation of why money is held (a hold word with a reason or risk word);
- names of private businesses. The deny list keeps real brand names only so the guard can recognise
  them;
- links, also spelled to get past a filter;
- four or more digits that are not an allowed public number.

A blocked answer shows a fixed safe line instead of the model's words. A code-like number from the
customer ends the voice session, drops the resumption handle and starts a clean session. In chat, the
app masks the digits before the question goes to the model.

Known limit: Live sends audio before the text of the same words. The guard checks text, so it can stop
the audio only after the first words of a bad answer have played. The instructions, the tool design and
the caption check reduce this risk.

## Half-duplex audio

`FNA_HALF_DUPLEX` is on by default. The microphone closes while FNA speaks, and the Stop button
interrupts. This keeps room noise and loudspeaker echo from interrupting FNA. With the flag off, the
session is full duplex and the customer can interrupt by voice.

When the app speaks a line itself (the held line, the call summary, "Hear it"), the session pauses for
that line. The microphone closes and Live audio stops, but the connection stays open, so a tool call
that waits for the line still gets its response.

## Server-only hold reasons

The model never receives the text of a hold reason. When the customer asks why money was held, the
model calls `show_hold_reason()`. The app then shows and speaks the server's own reason text and
returns `{shown: true}` to the model. A unit test (`test/features/apa/fna_fr3_test.dart`) checks every
model payload for hold reason text.

## Flags

| Define | Default | Meaning |
|---|---|---|
| `FNA_VOICE_AGENT` | `true` | Chat and voice views. `false` keeps the original sheet. |
| `FNA_HALF_DUPLEX` | `true` | Microphone closed while FNA speaks. |
| `APA_LIVE_MODEL` / `APA_LIVE_LOCATION` | `gemini-3.8-live` / `us-central1` | Live model and region. |
| `FNA_TEXT_MODEL` / `FNA_TEXT_FALLBACK_MODEL` | `gemini-3.8-flash` / `gemini-3.5-flash-lite` | Text agent models. |
| `FNA_TEXT_LOCATION` | `global` | Text agent region. The Gemini 3.x text models answer only on `global`. |
