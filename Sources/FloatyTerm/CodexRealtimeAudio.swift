import AVFoundation

/// Raw voice stays between the native host and the Codex sidecar, never WebKit.
/// All public operations run on the main queue. Each instance is one session.
final class CodexRealtimeAudio {
    let requestID = UUID().uuidString
    var onReady: (() -> Void)?
    var onAudio: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let pendingCapture = DispatchSemaphore(value: 2)
    private var sending = false
    private var captureEpoch = 0
    private var cancelled = false
    private var tapInstalled = false
    private var playbackFormat: AVAudioFormat?
    private var queuedSeconds: Double = 0
    private var playbackEpoch = 0
    private(set) var echoCancellationEnabled = false

    private enum StartupError: LocalizedError {
        case microphone, output
        var errorDescription: String? {
            switch self {
            case .microphone: return "No compatible microphone is available."
            case .output: return "No compatible audio output is available."
            }
        }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                guard granted else { self.fail("Microphone access is off. Enable it for FloatyTerm in System Settings › Privacy & Security › Microphone."); return }
                self.begin()
            }
        }
    }

    private func begin() {
        do {
            try configureAndStart(voiceProcessing: true)
            echoCancellationEnabled = true
        } catch {
            let processingError = error as NSError
            // VoiceProcessingIO may fail for mixed devices or unsupported routes.
            // Retry using new nodes: a failed initialization can leave the old
            // engine's audio unit and aggregate device in an unusable state.
            resetAudioGraph()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            do {
                try configureAndStart(voiceProcessing: false)
                echoCancellationEnabled = false
            } catch {
                let standardError = error as NSError
                fail("Voice audio could not start. Echo cancellation: \(processingError.localizedDescription) (\(processingError.code)). Standard audio: \(standardError.localizedDescription) (\(standardError.code)). Check the selected microphone and speakers in System Settings › Sound.")
                return
            }
        }
        onReady?()
    }

    private func configureAndStart(voiceProcessing: Bool) throws {
        // Realize both I/O nodes before changing their voice-processing mode.
        let input = engine.inputNode
        let outputNode = engine.outputNode
        if voiceProcessing { try input.setVoiceProcessingEnabled(true) }
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw StartupError.microphone
        }
        let hardwareOutput = outputNode.inputFormat(forBus: 0)
        guard hardwareOutput.sampleRate > 0, hardwareOutput.channelCount > 0 else { throw StartupError.output }
        engine.attach(player)
        let output = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: output)
        // VoiceProcessingIO requires matching client-side input/output
        // formats. Keep device I/O at the microphone's format, and let the
        // mixer resample 24 kHz playback. Ordinary I/O uses the output device
        // format so different microphone/speaker routes can still work.
        engine.connect(engine.mainMixerNode, to: outputNode, format: voiceProcessing ? source : hardwareOutput)
        playbackFormat = output
        var accumulated = Data()
        var lastEpoch = -1
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); let send = self.sending; let epoch = self.captureEpoch; self.lock.unlock()
            if lastEpoch != epoch { accumulated.removeAll(keepingCapacity: true); converter.reset(); lastEpoch = epoch }
            guard send else { accumulated.removeAll(keepingCapacity: true); return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24000 / source.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let samples = converted.int16ChannelData else {
                self.lock.lock(); self.sending = false; self.lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.fail("Microphone audio conversion failed.")
                }
                return
            }
            accumulated.append(Data(bytes: samples[0], count: Int(converted.frameLength) * 2))
            // 100ms chunks. Bound work waiting on the main thread.
            while accumulated.count >= 4800 {
                let chunk = Data(accumulated.prefix(4800)); accumulated.removeFirst(4800)
                guard self.pendingCapture.wait(timeout: .now()) == .success else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    defer { self.pendingCapture.signal() }
                    guard !self.cancelled else { return }
                    self.lock.lock(); let send = self.sending && self.captureEpoch == epoch; self.lock.unlock()
                    if send { self.onAudio?(["data": chunk.base64EncodedString(), "sampleRate": 24000, "numChannels": 1, "samplesPerChannel": 2400]) }
                }
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func setSending(_ enabled: Bool) {
        lock.lock(); captureEpoch += 1; sending = enabled && !cancelled; lock.unlock()
    }

    func play(_ audio: [String: Any]) {
        guard !cancelled,
              let encoded = audio["data"] as? String, encoded.count <= 512_000,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
              let rate = (audio["sampleRate"] as? NSNumber)?.doubleValue, (8000...96000).contains(rate),
              let channels = audio["numChannels"] as? Int, (1...2).contains(channels),
              bytes.count % (channels * 2) == 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else {
            if !cancelled { fail("Codex returned an unsupported audio chunk.") }; return
        }
        let frames = bytes.count / (channels * 2)
        if let declared = audio["samplesPerChannel"] as? Int, declared != frames { fail("Codex returned an invalid audio frame count."); return }
        let duration = Double(frames) / rate
        guard queuedSeconds + duration <= 4 else { fail("Voice playback fell behind. Start voice again."); return }
        if playbackFormat != format {
            player.stop(); playbackEpoch += 1; queuedSeconds = 0
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playbackFormat = format
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let samples = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let index = (frame * channels + channel) * 2
                    let value = Int16(bitPattern: UInt16(values[index]) | (UInt16(values[index + 1]) << 8))
                    samples[channel][frame] = Float(value) / 32768
                }
            }
        }
        queuedSeconds += duration
        let epoch = playbackEpoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackEpoch == epoch else { return }
                self.queuedSeconds = max(0, self.queuedSeconds - duration)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func clearPlayback() {
        player.stop(); playbackEpoch += 1; queuedSeconds = 0
    }

    func stop() {
        cancelled = true
        setSending(false)
        resetAudioGraph()
        onReady = nil; onAudio = nil
    }

    private func resetAudioGraph() {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop(); engine.stop()
        playbackEpoch += 1; queuedSeconds = 0
        playbackFormat = nil
        echoCancellationEnabled = false
    }

    private func fail(_ message: String) {
        stop()
        onError?(message)
        onError = nil
    }
}
