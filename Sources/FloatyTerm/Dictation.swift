import AVFoundation
import Speech

/// Dictation for the chat tab's mic button: the Mac's own speech recognition,
/// on the device when its language model is installed. (Claude Code's /voice
/// records inside its terminal UI only, so a tab on the Agent SDK cannot use it.)
///
/// `start()` asks for the Speech Recognition and Microphone permissions the
/// first time. Partial text arrives while you speak; `stop()` ends the audio,
/// and the final text follows.
final class Dictation {
    enum Event {
        case listening
        case text(String, final: Bool)
        case stopped
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard self.isRunning else { return }
                guard status == .authorized else {
                    self.fail(status == .notDetermined
                              ? "Speech recognition is not available."
                              : "Speech recognition is off for FloatyTerm. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard self.isRunning else { return }
                        guard granted else {
                            self.fail("FloatyTerm cannot use the microphone. Turn it on in System Settings › Privacy & Security › Microphone.")
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            fail("Speech recognition is not available. Check Siri and Dictation in System Settings.")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        // On the device: no audio leaves the Mac, and there is no one-minute limit.
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("No microphone was found."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch {
            fail("The microphone did not start: \(error.localizedDescription)")
            return
        }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.request === req else { return }
                if let result { self.onEvent?(.text(result.bestTranscription.formattedString, final: result.isFinal)) }
                if result?.isFinal == true { self.finish(nil) } else if let error { self.finish(error) }
            }
        }
        onEvent?(.listening)
    }

    /// Stops listening. The words heard so far still arrive, as the final text.
    func stop() {
        guard isRunning else { return }
        guard let req = request else { reset(); onEvent?(.stopped); return }   // still asking for permission
        stopAudio()
        req.endAudio()
        // The recognizer normally answers in well under a second; do not wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if let self, self.request === req { self.task?.cancel(); self.reset(); self.onEvent?(.stopped) }
        }
    }

    /// Stops at once, without the final text (the tab is closing).
    func cancel() {
        task?.cancel()
        reset()
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    private func reset() {
        stopAudio()
        request = nil
        task = nil
        isRunning = false
    }

    private func finish(_ error: Error?) {
        reset()
        // "No speech detected" and a cancelled request are ordinary ends, not failures.
        if let error = error as NSError?, ![203, 216, 301, 1110].contains(error.code) {
            onEvent?(.failed(error.localizedDescription))
        } else {
            onEvent?(.stopped)
        }
    }

    private func fail(_ message: String) {
        reset()
        onEvent?(.failed(message))
    }
}
