import Foundation

#if os(macOS)
import AVFoundation
import Speech

struct VoiceCaptureResult: Equatable, Sendable {
    let audioURL: URL
    let transcript: String
    let duration: TimeInterval
}

enum VoiceCaptureError: LocalizedError {
    case unavailable
    case notRecording
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .unavailable: tr("voice_capture_is_unavailable_right_now")
        case .notRecording: tr("no_recording_in_progress")
        case .noTranscript: tr("recording_finished_but_no_usable_transcript")
        }
    }
}

@MainActor
final class MacVoiceCaptureSession {
    private let recorder: AVAudioRecorder
    private let audioURL: URL

    init() throws {
        audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("light-anchor-voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        recorder = try AVAudioRecorder(url: audioURL, settings: settings)
        recorder.isMeteringEnabled = false
    }

    func start() throws {
        guard recorder.prepareToRecord(), recorder.record() else {
            throw VoiceCaptureError.unavailable
        }
    }

    func stop() async throws -> VoiceCaptureResult {
        guard recorder.isRecording else { throw VoiceCaptureError.notRecording }
        recorder.stop()
        let duration = recorder.currentTime
        let transcript = try await transcribe()
        guard !transcript.isEmpty else { throw VoiceCaptureError.noTranscript }
        return VoiceCaptureResult(
            audioURL: audioURL,
            transcript: transcript,
            duration: duration
        )
    }

    func cancel() {
        if recorder.isRecording { recorder.stop() }
        try? FileManager.default.removeItem(at: audioURL)
    }

    private func transcribe() async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable
        else { throw VoiceCaptureError.unavailable }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        let state = TranscriptionState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                state.begin(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let transcript = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if result.isFinal {
                            state.finish(returning: transcript)
                            return
                        }
                        state.note(transcript)
                    }
                    if let error {
                        state.finish(throwing: error)
                    }
                }
                state.attach(task)
                // Recognition runs on Apple's servers and can stop calling back
                // without ever reporting a final result or an error, which would
                // leave the capture hanging with no way out.
                DispatchQueue.global().asyncAfter(deadline: .now() + transcriptionTimeout) {
                    state.finish(throwing: VoiceCaptureError.noTranscript)
                }
            }
        }, onCancel: {
            state.abort()
        })
    }
}

private let transcriptionTimeout: DispatchTimeInterval = .seconds(60)

/// The recognition handler is called repeatedly and keeps firing after the
/// final result, so resuming it directly would resume the continuation twice.
private final class TranscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var isFinished = false

    func begin(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Held so cancellation and the deadline can stop recognition instead of
    /// leaving it running against a continuation nobody is waiting on.
    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let finishedBeforeAttach = isFinished
        recognitionTask = finishedBeforeAttach ? nil : task
        lock.unlock()
        if finishedBeforeAttach { task.cancel() }
    }

    func note(_ transcript: String) {
        lock.lock()
        latestTranscript = transcript
        lock.unlock()
    }

    private func takePending() -> (CheckedContinuation<String, Error>?, String, SFSpeechRecognitionTask?) {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        let task = recognitionTask
        let transcript = latestTranscript
        continuation = nil
        recognitionTask = nil
        isFinished = true
        return (pending, transcript, task)
    }

    func finish(returning transcript: String) {
        let (pending, _, task) = takePending()
        task?.finish()
        pending?.resume(returning: transcript)
    }

    /// Speech routinely reports an error right after transcribing, so keep the
    /// text already recognised rather than failing a capture that succeeded.
    func finish(throwing error: Error) {
        let (pending, transcript, task) = takePending()
        guard let pending else { return }
        task?.cancel()
        if transcript.isEmpty {
            pending.resume(throwing: error)
        } else {
            pending.resume(returning: transcript)
        }
    }

    func abort() {
        let (pending, _, task) = takePending()
        task?.cancel()
        pending?.resume(throwing: CancellationError())
    }
}
#endif
