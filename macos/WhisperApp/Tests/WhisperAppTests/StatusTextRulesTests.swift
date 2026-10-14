import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct StatusTextRulesTests {
    @Test func workerBadgeHiddenWhenReadyAndChineseOtherwise() {
        #expect(StatusTextRules.workerStatus(.ready) == nil)
        #expect(StatusTextRules.workerStatus(.starting) == "轉錄引擎啟動中…")
        #expect(StatusTextRules.workerStatus(.restarting(2)) == "轉錄引擎重新啟動中（第 2 次）…")
        #expect(StatusTextRules.workerStatus(.failed("exit 1")) == "轉錄引擎錯誤：exit 1")
        #expect(StatusTextRules.workerStatus(.stopped) == "轉錄引擎已停止")
    }

    @Test func standardStatusHiddenWhenIdle() {
        #expect(StatusTextRules.standardStatus(.idle) == nil)
        #expect(StatusTextRules.standardStatus(.ready) == nil)
        #expect(StatusTextRules.standardStatus(.recorded(URL(fileURLWithPath: "/tmp/a.wav"))) == nil)
        #expect(StatusTextRules.standardStatus(.requestingPermission) == "正在要求麥克風權限…")
        #expect(StatusTextRules.standardStatus(.recording(startedAt: Date())) == "錄音中…")
        #expect(StatusTextRules.standardStatus(.finalizing) == "正在儲存錄音…")
        #expect(StatusTextRules.standardStatus(.failed("x")) == "錄音錯誤：x")
    }

    @Test func liveStatusHiddenWhenIdle() {
        #expect(StatusTextRules.liveStatus(.idle) == nil)
        #expect(StatusTextRules.liveStatus(.requestingPermission) == "正在要求麥克風權限…")
        #expect(StatusTextRules.liveStatus(.recording) == "即時轉錄中…")
        #expect(StatusTextRules.liveStatus(.recovering) == "音訊裝置恢復中…")
        #expect(StatusTextRules.liveStatus(.stopping) == "停止中…")
        #expect(StatusTextRules.liveStatus(.draining) == "正在轉錄最後幾段…")
        #expect(StatusTextRules.liveStatus(.failed("x")) == "錄音錯誤：x")
    }

    @Test func mixedStatusFollowsTable() {
        func status(_ state: MixedAudioRecordingState, draining: Bool = false, error: String? = nil, mic: Bool = true) -> String? {
            StatusTextRules.mixedStatus(state, isDraining: draining, submissionError: error, includesMicrophone: mic)
        }
        #expect(status(.idle) == nil)
        #expect(status(.starting) == "啟動中…")
        #expect(status(.recording) == "錄音中（麥克風＋系統音訊）")
        #expect(status(.recording, mic: false) == "錄音中（系統音訊）")
        #expect(status(.recovering) == "音訊裝置恢復中…")
        #expect(status(.stopping) == "停止中…")
        #expect(status(.failed("x")) == "錄音錯誤：x")
        #expect(status(.idle, draining: true) == "正在轉錄最後幾段…")
        #expect(status(.recording, error: "timeout") == "轉錄暫停：timeout（請重新啟動轉錄引擎）")
    }

    @Test func primaryButtonIsShortVerbInEveryMode() {
        #expect(StatusTextRules.primaryButtonLabel(mode: .standard, isRecording: false) == "開始錄音")
        #expect(StatusTextRules.primaryButtonLabel(mode: .mixed, isRecording: false) == "開始錄音")
        #expect(StatusTextRules.primaryButtonLabel(mode: .live, isRecording: false) == "開始即時轉錄")
        #expect(StatusTextRules.primaryButtonLabel(mode: .standard, isRecording: true) == "停止並轉錄")
        #expect(StatusTextRules.primaryButtonLabel(mode: .mixed, isRecording: true) == "停止並轉錄")
        #expect(StatusTextRules.primaryButtonLabel(mode: .live, isRecording: true) == "停止即時模式")
    }

    @Test func jobAndModelAndLabelTextsAreChinese() {
        #expect(StatusTextRules.jobStatus("Queued") == "排隊中…")
        #expect(StatusTextRules.jobStatus("Transcribing") == "轉錄中…")
        #expect(StatusTextRules.jobStatus("⏳ 啟動模型中") == "⏳ 啟動模型中")
        #expect(StatusTextRules.modelReadiness("needs_download") == "第一次使用需要下載模型")
        #expect(StatusTextRules.modelReadiness("unknown") == "尚未檢查模型")
        #expect(AppSettingsStore.supportedDomains.map(StatusTextRules.domainName) == ["通用", "媒體", "科技", "醫療", "法律"])
        #expect(StatusTextRules.batchStatus(.pending) == "等待中")
    }
}
