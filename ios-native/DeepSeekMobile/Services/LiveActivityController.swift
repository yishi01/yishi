import ActivityKit
import AVFoundation
import Foundation
import UIKit

/// Doubao-style Dynamic Island Controller for Unjailbroken iOS + Pending Approval Review Banner.
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

    private(set) var pendingApprovalId: String = ""
    private(set) var pendingToolName: String = ""
    private(set) var pendingSummary: String = ""
    private(set) var pendingRiskLevel: String = ""
    private(set) var queuedCount: Int = 0

    private var isIslandFeatureEnabled: Bool {
        if let val = UserDefaults.standard.object(forKey: "ds_theme_dynamic_island") as? Bool {
            return val
        }
        return true
    }

    private init() {}

    func setSceneBackground(_ inBackground: Bool) {
        isInBackground = inBackground
        if inBackground {
            if isTurnActive || !pendingApprovalId.isEmpty {
                startBackgroundKeepAlive()
                startOrUpdateIsland(phase: pendingApprovalId.isEmpty ? latestPhase : .waitingApproval, toolCount: latestToolCount)
            }
        } else {
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
        self.pendingApprovalId = ""
        self.pendingToolName = ""
        self.pendingSummary = ""
        self.pendingRiskLevel = ""
        retractTask?.cancel()
        retractTask = nil

        if isInBackground {
            startBackgroundKeepAlive()
            startOrUpdateIsland(phase: .thinking, toolCount: 0)
        }
    }

    func notifyPhaseChanged(
        _ phase: DeepSeekIslandPhase,
        toolCount: Int = 0,
        approvalId: String = "",
        toolName: String = "",
        summary: String = "",
        riskLevel: String = "",
        queuedCount: Int = 0
    ) {
        self.latestPhase = phase
        self.latestToolCount = toolCount
        self.queuedCount = queuedCount
        if phase == .waitingApproval {
            self.pendingApprovalId = approvalId
            self.pendingToolName = toolName
            self.pendingSummary = summary
            self.pendingRiskLevel = riskLevel
        } else {
            self.pendingApprovalId = ""
            self.pendingToolName = ""
            self.pendingSummary = ""
            self.pendingRiskLevel = ""
        }
        guard (isTurnActive || !pendingApprovalId.isEmpty), isInBackground else { return }
        startOrUpdateIsland(phase: phase, toolCount: toolCount)
    }

    func clearPendingApproval() {
        self.pendingApprovalId = ""
        self.pendingToolName = ""
        self.pendingSummary = ""
        self.pendingRiskLevel = ""
        if isTurnActive && isInBackground {
            startOrUpdateIsland(phase: .callingTool, toolCount: latestToolCount)
        }
    }

    func notifyTurnFinished() {
        self.pendingApprovalId = ""
        self.pendingToolName = ""
        self.pendingSummary = ""
        self.pendingRiskLevel = ""
        guard isTurnActive else { return }
        isTurnActive = false
        latestPhase = .completed

        guard isInBackground else {
            stopBackgroundKeepAlive()
            Task { await endIslandImmediately() }
            return
        }

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
        guard isIslandFeatureEnabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = DeepSeekIslandAttributes.ContentState(
            phase: phase,
            toolCount: toolCount,
            pendingApprovalId: pendingApprovalId,
            pendingToolName: pendingToolName,
            pendingSummary: pendingSummary,
            pendingRiskLevel: pendingRiskLevel,
            queuedCount: queuedCount
        )

        if let activity = currentActivity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        } else {
            do {
                let attrs = DeepSeekIslandAttributes(sessionTitle: sessionTitle)
                let activity = try Activity.request(
                    attributes: attrs,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                self.currentActivity = activity
            } catch {}
        }
    }

    private func endIslandImmediately() async {
        let activities = Activity<DeepSeekIslandAttributes>.activities
        for act in activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    private func startBackgroundKeepAlive() {
        if bgTaskId == .invalid {
            bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "DeepSeekBridgeKeepAlive") { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    if self.bgTaskId != .invalid {
                        UIApplication.shared.endBackgroundTask(self.bgTaskId)
                        self.bgTaskId = .invalid
                    }
                }
            }
        }

        guard audioEngine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100.0
            let silenceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in ablPointer {
                    if let data = buffer.mData {
                        memset(data, 0, Int(frameCount) * Int(MemoryLayout<Float>.size))
                    }
                }
                return noErr
            }
            if let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: format.channelCount) {
                engine.attach(silenceNode)
                engine.connect(silenceNode, to: engine.mainMixerNode, format: sourceFormat)
                engine.mainMixerNode.outputVolume = 0.0
                try engine.start()
                self.audioEngine = engine
            }
        } catch {}
    }

    private func stopBackgroundKeepAlive() {
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if bgTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskId)
            bgTaskId = .invalid
        }
    }
}
