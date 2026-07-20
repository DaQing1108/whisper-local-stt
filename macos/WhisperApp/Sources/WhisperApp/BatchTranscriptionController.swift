import Foundation
import Observation

enum BatchItemStatus: String, Codable, Sendable {
    case pending, running, completed, failed, cancelled
}

struct BatchTranscriptionItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var status: BatchItemStatus
    var message: String?
}

enum BatchTranscriptionError: Error, Equatable {
    case capacityExceeded(Int)
    case workerBusy
}

@MainActor
@Observable
final class BatchTranscriptionController {
    static let defaultCapacity = 20
    private(set) var items: [BatchTranscriptionItem] = []
    private(set) var isRunning = false
    private let worker: WorkerSupervisor
    private let capacity: Int
    private var activeItemID: UUID?
    private var activeRequestID: String?
    private var terminalObserverID: UUID?
    private var lostObserverID: UUID?
    private var readyObserverID: UUID?
    private var unavailableObserverID: UUID?
    private var model = "base"
    private var language: String?
    private var domain = "general"
    private var extraTerms = ""

    init(worker: WorkerSupervisor, capacity: Int = defaultCapacity) {
        self.worker = worker
        self.capacity = capacity
        terminalObserverID = worker.addTerminalObserver { [weak self] requestID, status in
            self?.terminal(requestID: requestID, status: status)
        }
        lostObserverID = worker.addLostObserver { [weak self] requestID in
            self?.lost(requestID: requestID)
        }
        readyObserverID = worker.addReadyObserver { [weak self] in self?.submitNext() }
        unavailableObserverID = worker.addUnavailableObserver { [weak self] state in
            self?.workerBecameUnavailable(state)
        }
    }

    func replaceFiles(_ urls: [URL]) throws {
        guard !isRunning else { throw BatchTranscriptionError.workerBusy }
        guard urls.count <= capacity else { throw BatchTranscriptionError.capacityExceeded(capacity) }
        items = urls.map { BatchTranscriptionItem(id: UUID(), url: $0, status: .pending) }
    }

    func start(model: String, language: String?, domain: String, extraTerms: String) throws {
        guard !isRunning, worker.activeRequestID == nil else { throw BatchTranscriptionError.workerBusy }
        self.model = model
        self.language = language
        self.domain = domain
        self.extraTerms = extraTerms
        isRunning = true
        submitNext()
    }

    func cancelPending() {
        for index in items.indices where items[index].status == .pending {
            items[index].status = .cancelled
        }
        if activeItemID == nil { isRunning = false }
    }

    private func submitNext() {
        guard isRunning, worker.state == .ready, activeItemID == nil else { return }
        guard let index = items.firstIndex(where: { $0.status == .pending }) else {
            isRunning = false
            activeItemID = nil
            activeRequestID = nil
            return
        }
        do {
            let requestID = try worker.transcribe(
                audioURL: items[index].url, modelName: model, language: language,
                domain: domain, extraTerms: extraTerms
            )
            items[index].status = .running
            items[index].message = nil
            activeItemID = items[index].id
            activeRequestID = requestID
        } catch {
            items[index].status = .failed
            items[index].message = error.localizedDescription
            submitNext()
        }
    }

    private func terminal(requestID: String?, status: String) {
        guard requestID == activeRequestID,
              let activeItemID,
              let index = items.firstIndex(where: { $0.id == activeItemID }) else { return }
        switch status {
        case "Completed": items[index].status = .completed; items[index].message = nil
        case "Cancelled": items[index].status = .cancelled; items[index].message = nil
        default:
            items[index].status = .failed
            items[index].message = status
        }
        self.activeItemID = nil
        activeRequestID = nil
        submitNext()
    }

    private func lost(requestID: String) {
        guard requestID == activeRequestID,
              let activeItemID,
              let index = items.firstIndex(where: { $0.id == activeItemID }) else { return }
        items[index].status = .pending
        items[index].message = "Waiting for Worker restart"
        self.activeItemID = nil
        activeRequestID = nil
        if worker.state == .ready { submitNext() }
    }

    private func workerBecameUnavailable(_ state: WorkerState) {
        guard isRunning else { return }
        let message: String
        if case .failed(let detail) = state { message = detail }
        else { message = "Worker stopped before batch completion" }
        for index in items.indices where items[index].status == .pending || items[index].status == .running {
            items[index].status = .failed
            items[index].message = message
        }
        activeItemID = nil
        activeRequestID = nil
        isRunning = false
    }
}
