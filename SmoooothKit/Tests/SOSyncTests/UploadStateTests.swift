import Testing
@testable import SOSync

@Suite("UploadState machine")
struct UploadStateTests {
    @Test("happy path: pending → uploading → uploaded")
    func happyPath() {
        #expect(UploadState.pending.canTransition(to: .uploading))
        #expect(UploadState.uploading.canTransition(to: .uploaded))
    }

    @Test("failure path allows retry: uploading → failed → uploading")
    func retryPath() {
        #expect(UploadState.uploading.canTransition(to: .failed))
        #expect(UploadState.failed.canTransition(to: .uploading))
    }

    @Test("uploaded is terminal")
    func terminal() {
        for state in UploadState.allCases {
            #expect(!UploadState.uploaded.canTransition(to: state))
        }
    }

    @Test("illegal jumps are rejected")
    func illegalJumps() {
        #expect(!UploadState.pending.canTransition(to: .uploaded))  // must upload first
        #expect(!UploadState.pending.canTransition(to: .failed))    // nothing attempted yet
        #expect(!UploadState.failed.canTransition(to: .uploaded))   // must retry through uploading
    }

    @Test("no state transitions to itself")
    func noSelfLoops() {
        for state in UploadState.allCases {
            #expect(!state.canTransition(to: state))
        }
    }
}
