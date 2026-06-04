#if DEBUG
    actor StoreBackedWorkspaceSearchSharedAdmissionTestLease {
        static let shared = StoreBackedWorkspaceSearchSharedAdmissionTestLease()

        private var isHeld = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func withLease(_ operation: () async throws -> Void) async rethrows {
            await acquire()
            defer { release() }
            try await operation()
        }

        private func acquire() async {
            guard isHeld else {
                isHeld = true
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        private func release() {
            guard !waiters.isEmpty else {
                isHeld = false
                return
            }
            waiters.removeFirst().resume()
        }
    }
#endif
