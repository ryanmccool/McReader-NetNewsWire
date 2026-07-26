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
}

private enum TestError: Error {
	case expected
}
