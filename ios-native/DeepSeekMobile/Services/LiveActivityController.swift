import ActivityKit
import AVFoundation
import Foundation
import UIKit

/// Doubao-style Dynamic Island Controller for Unjailbroken iOS:
/// 1. Only shows Dynamic Island when the app switches to background AND AI is actively running.
/// 2. Displays ONLY the minimal phase (深度思考 / 工具调用 / 待确认), never verbose content.
/// 3. When output finishes in background, shows "输出完成" for 2.2s and automatically retracts.
/// 4. Uses a zero-volume mixWithOthers audio session while running in background so unjailbroken iOS
///    does not freeze the WebSocket before "输出完成" retracts the island.
@MainActor
final class LiveActivityController: ObservableObject {
    static let shared = LiveActivityController()

    private var currentActivity: Activity<DeepSeekIslandAttributes>?
    private var retractTask: Task<Void, Never>?
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var audioEngine: AVAudioEngine?

    private(set) var isInBackground: Bool = false
    private(set) var isTurnActive: Bool = false
    private(set) var latestPhase: DeepSeekIslandPhase = .thinking
    private(set) var latestToolCount: Int = 0
    private(set) var sessionTitle: String = "DeepSeek"

    private init() {}

    func setSceneBackground(_ inBackground: Bool) {
        isInBackground = inBackground
        if inBackground {
            if isTurnActive {
                startBackgroundKeepAlive()
                startOrUpdateIsland(phase: latestPhase, toolCount: latestToolCount)
            }
        } else {
            // Returned to foreground: retract Dynamic Island immediately (Doubao behavior)
            retractTask?.cancel()
            retractTask = nil
            stopBackgroundKeepAlive()
            Task {
                await endIslandImmediately()
            }
        }
    }

    func notifyTurnStarted(sessionTitle: String) {
        self.sessionTitle = sessionTitle
        self.isTurnActive = true
        self.latestPhase = .thinking
        self.latestToolCount = 0
        retractTask?.cancel()
        retractTask = nil

        if isInBackground {
            startBackgroundKeepAlive()
            startOrUpdateIsland(phase: .thinking, toolCount: 0)
        }
    }

    func notifyPhaseChanged(_ phase: DeepSeekIslandPhase, toolCount: Int = 0) {
        self.latestPhase = phase
        self.latestToolCount = toolCount
        guard isTurnActive, isInBackground else { return }
        startOrUpdateIsland(phase: phase, toolCount: toolCount)
    }

    func notifyTurnFinished() {
        guard isTurnActive else { return }
        isTurnActive = false
        latestPhase = .completed

        guard isInBackground else {
            stopBackgroundKeepAlive()
            Task { await endIslandImmediately() }
            return
        }

        // In background: show "输出完成" briefly (2.2s), then retract the Dynamic Island
        startOrUpdateIsland(phase: .completed, toolCount: latestToolCount)
        retractTask?.cancel()
        retractTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            await endIslandImmediately()
            stopBackgroundKeepAlive()
        }
    }

    private func startOrUpdateIsland(phase: DeepSeekIslandPhase, toolCount: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = DeepSeekIslandAttributes.ContentState(phase: phase, toolCount: toolCount)

        if let activity = currentActivity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        } else {
            do {
                let attrs = DeepSeekIslandAttributes(sessionTitle: sessionTitle)
                let content = ActivityContent(state: state, staleDate: nil)
                currentActivity = try Activity.request(
                    attributes: attrs,
                    content: content,
                    pushType: nil
                )
            } catch {
                // Ignore if Live Activities are disabled by user or signing profile
            }
        }
    }

    private func endIslandImmediately() async {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        let finalState = DeepSeekIslandAttributes.ContentState(
            phase: .completed,
            toolCount: latestToolCount
        )
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
    }

    // MARK: - Unjailbroken Background Keep-Alive (Only during active AI turn)

    private func startBackgroundKeepAlive() {
        if bgTaskId == .invalid {
            bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "DeepSeekTurn") { [weak self] in
                Task { @MainActor in
                    self?.stopBackgroundKeepAlive()
                }
            }
        }
        guard audioEngine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let src = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buf in abl {
                    if let ptr = buf.mData {
                        memset(ptr, 0, Int(buf.mDataByteSize))
                    }
                }
                return noErr
            }
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: nil)
            engine.mainMixerNode.outputVolume = 0.0
            try engine.start()
            self.audioEngine = engine
        } catch {
            // Fallback to standard UIBackgroundTask only
        }
    }

    private func stopBackgroundKeepAlive() {
        if let engine = audioEngine {
            engine.stop()
            audioEngine = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }
}
