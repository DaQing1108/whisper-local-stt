import Foundation
import Testing
@testable import WhisperApp

struct SystemAudioCallbackGateTests {
    @Test
    func closedGenerationRejectsLateCallback() {
        let gate = SystemAudioCallbackGate()
        let generation = gate.open()
        #expect(gate.begin(generation: generation))
        gate.end(generation: generation)
        gate.close(generation: generation)

        #expect(!gate.begin(generation: generation))
    }

    @Test
    func closeWaitsForAcceptedCallbackToFinish() async {
        let gate = SystemAudioCallbackGate()
        let generation = gate.open()
        #expect(gate.begin(generation: generation))

        let closeTask = Task.detached { gate.close(generation: generation) }
        await Task.yield()
        #expect(!closeTask.isCancelled)

        gate.end(generation: generation)
        await closeTask.value
        #expect(!gate.begin(generation: generation))
    }

    @Test
    func staleCloseDoesNotWaitForANewerGeneration() {
        let gate = SystemAudioCallbackGate()
        let first = gate.open()
        gate.close(generation: first)

        let second = gate.open()
        #expect(gate.begin(generation: second))
        gate.close(generation: first)

        gate.end(generation: second)
        gate.close(generation: second)
    }
}
