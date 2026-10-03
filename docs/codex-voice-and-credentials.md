# Codex voice and credential refresh

## Voice

In a Codex chat, **Voice** beside the composer starts a voice conversation. The first start requests macOS microphone access. The session panel exposes **Mute microphone / Unmute microphone** and **End voice**. Dictation remains a separate composer feature.

`CodexRealtimeAudio.swift` captures audio with AVAudioEngine voice processing (speaker echo cancellation), explicitly matches input/output client formats, and converts it to mono signed PCM16 at 24 kHz and sends 100 ms base64 chunks to the native Codex sidecar. If voice processing fails to initialize, a fresh engine retries with ordinary audio using the output device’s native format. The chat reports that echo cancellation is unavailable and recommends headphones. If both attempts fail, the error includes each audio failure code. Capture waits for `thread/realtime/started` before transmission. Muting discards microphone samples and queued chunks; assistant playback continues. Starting dictation ends realtime voice, and starting realtime voice cancels dictation.

The sidecar starts `thread/realtime/start` with audio output, WebSocket transport and protocol v1. It forwards capture through `thread/realtime/appendAudio`. Output audio uses the declared sample rate/channel count, validates complete PCM16 frames, and plays through AVAudioPlayerNode. The CLI selects its realtime model and voice defaults. WebRTC/SDP transport is not used.

Audio bytes use native IPC messages intercepted before WebKit. DOM events carry only state, transcripts and throttled audio metadata. Capture work is bounded to two queued main-thread chunks; excessive main-thread load drops capture chunks. RPC backlog/timeout or excessive playback backlog ends the voice session with a visible error. Queued capture is invalidated on mute/end. A new user transcript interrupts queued assistant playback. Capture and playback stop on tab/conversation switch, sidecar exit/restart, TUI handoff, new conversation, or tab cleanup. Stop during startup stops native audio immediately and waits for startup settlement before stopping the remote session. If remote stop cannot be confirmed, voice restart is blocked until the conversation is reopened.

Only explicit user start requests microphone access. Account/model support can still reject a realtime session; the server error is displayed. The installed CLI reports `realtime_conversation` enabled. The subsequent [manual QA](codex-voice-manual-qa.md) confirmed native startup, mute/unmute, stop and rendered local playback; live Codex speech remains blocked by API-key authentication, and spoken-word capture is not yet verified.

## Credentials

The session account panel provides **Refresh credentials**, **Sign in with ChatGPT**, and **Cancel sign-in** while login is pending. **More → Check Codex account** refreshes account metadata. Initial connection checks account state without forcing renewal.

Refresh invokes `account/read` with `refreshToken: true`; Codex owns the managed OAuth refresh and credential storage. Browser sign-in invokes `account/login/start` with `type: chatgpt`; the native host validates and opens the returned OpenAI HTTPS authentication URL. App-server owns the browser callback. Completion updates identity and account limits; failure offers sign-in recovery. Cancellation uses the exact pending login ID.

FloatyTerm neither reads the CLI token file nor requests, exports or stores tokens. Account metadata and status enter the DOM; the OAuth URL stays in native IPC. API keys and provider-managed credentials are checked but are not renewed through the ChatGPT refresh flow. The experimental externally owned token callback (`account/chatgptAuthTokens/refresh`) is rejected explicitly and offers managed sign-in recovery; FloatyTerm has no separate external token provider. Attestation remains unsupported.

The managed flow follows the [official app-server authentication contract](https://learn.chatgpt.com/docs/app-server). Audio capture uses [Realtime PCM16 framing](https://developers.openai.com/api/docs/guides/realtime-conversations) and the installed app-server audio-chunk schemas. Swift compilation, JS syntax and plist parsing passed. No live credential renewal or browser login was performed.

## Persistent preview

The component lab retains its existing IDs and saved review notes. **Implemented renderer** opens `Resources/SkimRender/dev/codex-event-surfaces.html`, which now includes interactive synthetic voice/account states. Preview actions never record audio, access credentials or open a sign-in browser.
