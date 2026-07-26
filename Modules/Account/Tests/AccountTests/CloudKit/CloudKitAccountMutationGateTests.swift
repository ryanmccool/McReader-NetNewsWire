//
//  CloudKitAccountMutationGateTests.swift
//  AccountTests
//

import XCTest
@testable import Account

@MainActor final class CloudKitAccountMutationGateTests: XCTestCase {

	func testMutationOwnsGateAcrossSuspensionAndRejectsSecondOperation() async throws {
		let gate = CloudKitAccountMutationGate()
		let operationStarted = expectation(description: "operation started")
		let releaseOperation = AsyncStream.makeStream(of: Void.self)

		let firstOperation = Task {
			try await gate.withMutation(kind: .importOPML) {
				operationStarted.fulfill()
				for await _ in releaseOperation.stream {
					break
				}
			}
		}

		await fulfillment(of: [operationStarted])
		XCTAssertEqual(gate.activeKind, .importOPML)

		do {
			try await gate.withMutation(kind: .feed) {}
			XCTFail("Expected a concurrent mutation to be rejected")
		} catch AccountError.operationInProgress {
			// Expected.
		}

		releaseOperation.continuation.yield()
		releaseOperation.continuation.finish()
		try await firstOperation.value
		XCTAssertNil(gate.activeKind)
	}

	func testStateNotificationIsBalancedWhenOperationThrows() async {
		let gate = CloudKitAccountMutationGate()
		var states = [CloudKitAccountMutationKind?]()
		let observer = NotificationCenter.default.addObserver(
			forName: .CloudKitAccountMutationStateDidChange,
			object: gate,
			queue: nil
		) { _ in
			MainActor.assumeIsolated {
				states.append(gate.activeKind)
			}
		}
		defer { NotificationCenter.default.removeObserver(observer) }

		do {
			try await gate.withMutation(kind: .refresh) {
				throw TestError.expected
			}
			XCTFail("Expected operation error")
		} catch TestError.expected {
			// Expected.
		} catch {
			XCTFail("Unexpected error: \(error)")
		}

		XCTAssertEqual(states, [.refresh, nil])
	}

	func testResetOwnsGateAcrossSuspensionAndRejectsAccountMutations() async throws {
		let gate = CloudKitAccountMutationGate()
		let resetStarted = expectation(description: "reset started")
		let releaseReset = AsyncStream.makeStream(of: Void.self)

		let reset = Task {
			try await gate.withMutation(kind: .reset) {
				resetStarted.fulfill()
				for await _ in releaseReset.stream {
					break
				}
			}
		}

		await fulfillment(of: [resetStarted])
		XCTAssertEqual(gate.activeKind, .reset)
		for kind in [CloudKitAccountMutationKind.importOPML, .feed, .folder, .articleStatus, .refresh, .remoteNotification] {
			do {
				try await gate.withMutation(kind: kind) {}
				XCTFail("Expected \(kind) to be rejected during reset")
			} catch AccountError.operationInProgress {
				// Expected.
			}
		}

		releaseReset.continuation.yield()
		releaseReset.continuation.finish()
		try await reset.value
		XCTAssertNil(gate.activeKind)
	}

	func testArticleStatusOwnsGateAndRejectsReset() async throws {
		let gate = CloudKitAccountMutationGate()
		let statusStarted = expectation(description: "status sync started")
		let releaseStatus = AsyncStream.makeStream(of: Void.self)

		let status = Task {
			try await gate.withMutation(kind: .articleStatus) {
				statusStarted.fulfill()
				for await _ in releaseStatus.stream {
					break
				}
			}
		}

		await fulfillment(of: [statusStarted])
		XCTAssertEqual(gate.activeKind, .articleStatus)
		do {
			try await gate.withMutation(kind: .reset) {}
			XCTFail("Expected reset to reject an active status mutation")
		} catch AccountError.operationInProgress {
			// Expected.
		}

		releaseStatus.continuation.yield()
		releaseStatus.continuation.finish()
		try await status.value
		XCTAssertNil(gate.activeKind)
	}
}

private enum TestError: Error {
	case expected
}
