//
//  DictationAudioCapture.swift
//  Clawline
//
//  Created by Codex on 2/13/26.
//

import AVFoundation
import CoreAudio
import Foundation
import OSLog

protocol DictationAudioCapturing: AnyObject {
    var frameStream: AsyncStream<Data> { get }
    var levelStream: AsyncStream<Float> { get }
    var eventStream: AsyncStream<DictationAudioCaptureEvent> { get }

    func start() throws
    func stop()
}

enum DictationAudioCaptureEvent: Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
    case mediaServicesReset
    case failed(message: String)
}

enum DictationAudioCaptureError: LocalizedError {
    case missingInputNode
    case outputFormatUnavailable
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingInputNode:
            return "No audio input node available."
        case .outputFormatUnavailable:
            return "Failed to allocate Soniox output format."
        case .converterCreationFailed:
            return "Failed to create PCM converter for dictation."
        }
    }
}

final class DictationAudioCapture: DictationAudioCapturing {
    private let logger = Logger(subsystem: "co.clicketyclacks.Clawline", category: "DictationAudioCapture")
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "co.clicketyclacks.Clawline.dictation.audio")
    private let lifecycleQueue = DispatchQueue(label: "co.clicketyclacks.Clawline.dictation.audio.lifecycle")

    private var continuationFrames: AsyncStream<Data>.Continuation?
    private var continuationLevels: AsyncStream<Float>.Continuation?
    private var continuationEvents: AsyncStream<DictationAudioCaptureEvent>.Continuation?
    private let _frameStream: AsyncStream<Data>
    private let _levelStream: AsyncStream<Float>
    private let _eventStream: AsyncStream<DictationAudioCaptureEvent>

    private let outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var frameAccumulator = Data()
    private var lastLevelEmitTime = CFAbsoluteTimeGetCurrent()
    private var isRunning = false
    private var isInterrupted = false
    private var isTapInstalled = false
#if os(iOS)
    private var audioSessionObservers: [NSObjectProtocol] = []
#endif

    init(outputFormat: AVAudioFormat? = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)) {
        self.outputFormat = outputFormat

        var frameContinuation: AsyncStream<Data>.Continuation?
        self._frameStream = AsyncStream { frameContinuation = $0 }
        self.continuationFrames = frameContinuation

        var levelContinuation: AsyncStream<Float>.Continuation?
        self._levelStream = AsyncStream { levelContinuation = $0 }
        self.continuationLevels = levelContinuation

        var eventContinuation: AsyncStream<DictationAudioCaptureEvent>.Continuation?
        self._eventStream = AsyncStream { eventContinuation = $0 }
        self.continuationEvents = eventContinuation
    }

    var frameStream: AsyncStream<Data> { _frameStream }
    var levelStream: AsyncStream<Float> { _levelStream }
    var eventStream: AsyncStream<DictationAudioCaptureEvent> { _eventStream }

    @discardableResult
    private func withLifecycleLock<T>(_ block: () throws -> T) throws -> T {
        var result: Result<T, Error>!
        lifecycleQueue.sync {
            result = Result { try block() }
        }
        return try result.get()
    }

    func start() throws {
        try withLifecycleLock {
            guard !isRunning else { return }
            frameAccumulator.removeAll(keepingCapacity: true)
            isInterrupted = false

            guard let outputFormat else {
                throw DictationAudioCaptureError.outputFormatUnavailable
            }

            try configureAudioSession()
            try configureEngineGraph(outputFormat: outputFormat)
            observeAudioSessionNotifications()

            engine.prepare()
            isRunning = true
            do {
                try engine.start()
            } catch {
                isRunning = false
                teardownEngineGraph()
                stopObservingAudioSessionNotifications()
                deactivateAudioSession()
                throw error
            }
        }
    }

    func stop() {
        lifecycleQueue.sync {
            guard isRunning else { return }
            isRunning = false
            isInterrupted = false
            teardownEngineGraph()
            stopObservingAudioSessionNotifications()
            deactivateAudioSession()
        }
    }

    private func configureAudioSession() throws {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setPreferredSampleRate(16_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
#endif
    }

    private func configureEngineGraph(outputFormat: AVAudioFormat) throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        guard converter != nil else {
            throw DictationAudioCaptureError.converterCreationFailed
        }

        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }
        isTapInstalled = true
    }

    private func teardownEngineGraph() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()

        queue.sync {
            self.converter = nil
            self.frameAccumulator.removeAll(keepingCapacity: false)
        }
    }

#if os(iOS)
    private func observeAudioSessionNotifications() {
        guard audioSessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        audioSessionObservers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleInterruptionNotification(notification)
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleRouteChangeNotification(notification)
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleMediaServicesResetNotification(notification)
            }
        ]
    }

    private func stopObservingAudioSessionNotifications() {
        let center = NotificationCenter.default
        for observer in audioSessionObservers {
            center.removeObserver(observer)
        }
        audioSessionObservers.removeAll()
    }

    private func handleInterruptionNotification(_ notification: Notification) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            guard self.isRunning else { return }
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else {
                return
            }

            switch type {
            case .began:
                self.isInterrupted = true
                self.engine.pause()
                self.continuationEvents?.yield(.interruptionBegan)
            case .ended:
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                let shouldResume = options.contains(.shouldResume)
                self.continuationEvents?.yield(.interruptionEnded(shouldResume: shouldResume))
                guard shouldResume else { return }
                do {
                    try self.configureAudioSession()
                    if !self.engine.isRunning {
                        try self.engine.start()
                    }
                    self.isInterrupted = false
                } catch {
                    self.continuationEvents?.yield(.failed(message: "Audio interruption recovery failed: \(error.localizedDescription)"))
                }
            @unknown default:
                break
            }
        }
    }

    private func handleRouteChangeNotification(_ notification: Notification) {
        guard isRunning else { return }
        continuationEvents?.yield(.routeChanged)

        let reasonRawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonRawValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
        let shouldRecover: Bool
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .noSuitableRouteForCategory:
            shouldRecover = true
        case .categoryChange, .routeConfigurationChange, .override, .wakeFromSleep, .unknown:
            shouldRecover = false
        @unknown default:
            shouldRecover = false
        }
        guard shouldRecover else { return }

        guard let outputFormat else { return }
        do {
            teardownEngineGraph()
            try configureAudioSession()
            try configureEngineGraph(outputFormat: outputFormat)
            engine.prepare()
            try engine.start()
            isInterrupted = false
        } catch {
            continuationEvents?.yield(.failed(message: "Audio route change recovery failed: \(error.localizedDescription)"))
        }
    }

    private func handleMediaServicesResetNotification(_ notification: Notification) {
        guard isRunning else { return }
        continuationEvents?.yield(.mediaServicesReset)

        guard let outputFormat else { return }
        do {
            teardownEngineGraph()
            engine = AVAudioEngine()
            try configureAudioSession()
            try configureEngineGraph(outputFormat: outputFormat)
            engine.prepare()
            try engine.start()
            isInterrupted = false
        } catch {
            continuationEvents?.yield(.failed(message: "Audio services reset recovery failed: \(error.localizedDescription)"))
        }
    }
#else
    private func observeAudioSessionNotifications() {}
    private func stopObservingAudioSessionNotifications() {}
#endif

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }
        guard !isInterrupted else { return }
        emitLevelIfNeeded(from: buffer)

        guard let copied = copyBuffer(buffer) else { return }
        queue.async { [weak self] in
            self?.processBuffer(copied)
        }
    }

    private func emitLevelIfNeeded(from buffer: AVAudioPCMBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelEmitTime >= 0.05 else { return }
        lastLevelEmitTime = now

        let rms = rmsLevel(for: buffer)
        continuationLevels?.yield(rms)
    }

    private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<frameLength {
                let sample = samples[index]
                sum += sample * sample
            }
            return sqrt(sum / Float(frameLength))
        }

        if let channelData = buffer.int16ChannelData {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<frameLength {
                let sample = Float(samples[index]) / Float(Int16.max)
                sum += sample * sample
            }
            return sqrt(sum / Float(frameLength))
        }

        return 0
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in 0..<sourceBuffers.count {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
                return nil
            }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
            destinationBuffers[index] = destinationBuffer
        }
        return copy
    }

    private func processBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
            logger.notice("[DICTATION-PERF] processBuffer: \(elapsedMs, privacy: .public)ms")
        }
        guard isRunning else { return }
        guard let converter else { return }
        guard let outputFormat else { return }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 16)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, statusPointer in
            if supplied {
                statusPointer.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPointer.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            logger.notice("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        guard converted.frameLength > 0 else { return }
        guard let pcmData = pcmData(from: converted), !pcmData.isEmpty else { return }
        frameAccumulator.append(pcmData)

        // 20ms at 16kHz mono PCM16 = 320 samples * 2 bytes = 640 bytes.
        let targetFrameBytes = 640
        while frameAccumulator.count >= targetFrameBytes {
            let chunk = frameAccumulator.prefix(targetFrameBytes)
            continuationFrames?.yield(Data(chunk))
            frameAccumulator.removeFirst(targetFrameBytes)
        }
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData else { return nil }
        return Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
    }

    private func deactivateAudioSession() {
#if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.notice("Failed to deactivate AVAudioSession: \(error.localizedDescription, privacy: .public)")
        }
#endif
    }
}
