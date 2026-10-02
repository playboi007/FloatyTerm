# Manual voice QA — 2026-10-02

Used two isolated, signed native windows with current production code. The user's existing FloatyTerm process and conversations remained open. Temporary QA entry points and output observation were restored afterward; no audio recordings or credential values were saved.

## Actual Codex chat

- Clicked the production Voice control through macOS Accessibility.
- Native audio initialized: the previously reported AVFAudio `-10875` did not recur.
- The installed `codex-cli 0.160.0` rejected session startup with `realtime conversation requires API key auth`.
- The current test environment had neither `OPENAI_API_KEY` nor `CODEX_API_KEY`. The chat displayed the failure and stopped native audio.
- This is an authentication limitation; it prevents a claim that live Codex speech playback works.

## Native microphone / PCM playback

Used the production `CodexRealtimeAudio` class with manual Start, Mute, Play local tone and Stop controls. A temporary mixer-output tap observed rendered buffers, without saving audio.

- Startup succeeded with echo cancellation enabled. Default microphone: built-in MacBook microphone, 48 kHz. Default output: Bluetooth speaker, 44.1 kHz. Matching client-side formats allowed this route to initialize.
- Capture delivered 100 ms PCM chunks.
- The first playback attempt found a numeric sample-rate parsing issue with a Swift integer value. Changed parsing to `NSNumber.doubleValue`, which accepts integer metadata as well as floating-point values.
- Repeated playback succeeded: a one-second 24 kHz PCM16 tone produced 52,800 nonzero observed output frames including render tails; maximum rendered peak `0.14648405`.
- Muting held capture at 19 chunks across later UI observations. Unmuting resumed capture to 64 chunks.
- Stopping held capture at 84 chunks across later UI observations.
- Captured microphone samples had peak `0.0`; spoken-word capture was **not verified**. The device reported unmuted input and volume approximately `0.275`. A phrase played through the system speaker did not produce a captured signal, so that was not accepted as evidence of speech capture.

## Outstanding

- Repeat actual voice session with a configured API key.
- Confirm spoken input near the microphone produces a transcript.
- Confirm actual Codex reply audio, production mute/unmute, and production session stop.
- The fallback without echo cancellation compiled but was not forced in the manual run; the primary path succeeded.
