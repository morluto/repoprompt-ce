// MARK: - DEBUG MCP Read/Search Latency Diagnostics

import Foundation
import MCP

#if DEBUG
    extension ServerNetworkManager {
        func debugMCPReadSearchCaptureBeginPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            guard let rawLabel = debugString(arguments, "label"),
                  let label = debugMCPReadSearchCaptureLabel(rawLabel)
            else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "Missing required non-empty string argument `label`.")
            }

            let maxSamples: Int
            switch debugBoundedInt(arguments, "max_samples", defaultValue: 20000, range: 100 ... 100_000) {
            case let .value(parsed), let .defaulted(parsed):
                maxSamples = parsed
            case .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_samples` must be an integer between 100 and 100000.")
            }

            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "capture": snapshot.payload()
                ])
            case let .busy(snapshot):
                return debugDiagnosticsError(
                    op: op,
                    code: "capture_busy",
                    message: "A read/search latency capture is already active with label `\(snapshot.label)`."
                )
            }
        }

        func debugMCPReadSearchCaptureSnapshotPayload(op: String, arguments: [String: Value]) -> CallTool.Result {
            let finish = debugBool(arguments, "finish") ?? true
            let includeTimeline = debugBool(arguments, "include_timeline") ?? true
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: finish)
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "capture": snapshot.payload(includeTimeline: includeTimeline)
            ])
        }

        func debugMCPReadSearchAdmissionSnapshotPayload(op: String) async -> CallTool.Result {
            let snapshot = await StoreBackedWorkspaceSearchAdmissionCoordinator.shared.snapshotForDebug()
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "admission": snapshot.payload()
            ])
        }

        func debugMCPReadSearchAdmissionConfigurePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let perStoreCapacity: Int
            switch debugBoundedInt(arguments, "per_store_capacity", defaultValue: 0, range: 1 ... 4) {
            case let .value(parsed):
                perStoreCapacity = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`per_store_capacity` must be an integer between 1 and 4.")
            }

            let globalCapacity: Int
            switch debugBoundedInt(arguments, "global_capacity", defaultValue: 0, range: 1 ... 128) {
            case let .value(parsed):
                globalCapacity = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`global_capacity` must be an integer between 1 and 128.")
            }

            let maxQueuedPerStore: Int
            switch debugBoundedInt(arguments, "max_queued_per_store", defaultValue: -1, range: 0 ... 256) {
            case let .value(parsed):
                maxQueuedPerStore = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queued_per_store` must be an integer between 0 and 256.")
            }

            let maxQueuedGlobally: Int
            switch debugBoundedInt(arguments, "max_queued_global", defaultValue: -1, range: 0 ... 1024) {
            case let .value(parsed):
                maxQueuedGlobally = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queued_global` must be an integer between 0 and 1024.")
            }

            let maxQueueWaitMilliseconds: Int
            switch debugBoundedInt(arguments, "max_queue_wait_ms", defaultValue: 0, range: 100 ... 60000) {
            case let .value(parsed):
                maxQueueWaitMilliseconds = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queue_wait_ms` must be an integer between 100 and 60000.")
            }

            let configuration = StoreBackedWorkspaceSearchAdmissionCoordinator.Configuration(
                perStoreCapacity: perStoreCapacity,
                globalCapacity: globalCapacity,
                maxQueuedPerStore: maxQueuedPerStore,
                maxQueuedGlobally: maxQueuedGlobally,
                maxQueueWait: .milliseconds(maxQueueWaitMilliseconds)
            )
            switch await StoreBackedWorkspaceSearchAdmissionCoordinator.shared.configureForDebug(configuration) {
            case let .applied(snapshot):
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "admission": snapshot.payload()
                ])
            case let .busy(snapshot):
                return debugDiagnosticsResult([
                    "ok": false,
                    "op": op,
                    "code": "admission_busy",
                    "error": "Read/search admission configuration can only change while the coordinator is idle.",
                    "admission": snapshot.payload()
                ], isError: true)
            }
        }

        func debugMCPReadSearchContentFetchAdmissionSnapshotPayload(op: String) async -> CallTool.Result {
            let snapshot = await StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.shared.snapshotForDebug()
            return debugDiagnosticsResult([
                "ok": true,
                "op": op,
                "admission": snapshot.payload()
            ])
        }

        func debugMCPReadSearchContentFetchAdmissionConfigurePayload(op: String, arguments: [String: Value]) async -> CallTool.Result {
            let fairSharePerStore: Int
            switch debugBoundedInt(arguments, "fair_share_per_store", defaultValue: 0, range: 1 ... 8) {
            case let .value(parsed):
                fairSharePerStore = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`fair_share_per_store` must be an integer between 1 and 8.")
            }

            let maxBurstPerStore: Int
            switch debugBoundedInt(arguments, "max_burst_per_store", defaultValue: 0, range: 1 ... 8) {
            case let .value(parsed):
                maxBurstPerStore = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_burst_per_store` must be an integer between 1 and 8.")
            }
            guard maxBurstPerStore >= fairSharePerStore else {
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_burst_per_store` must be greater than or equal to `fair_share_per_store`.")
            }

            let globalCapacity: Int
            switch debugBoundedInt(arguments, "global_capacity", defaultValue: 0, range: 1 ... 128) {
            case let .value(parsed):
                globalCapacity = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`global_capacity` must be an integer between 1 and 128.")
            }

            let maxQueuedPerStore: Int
            switch debugBoundedInt(arguments, "max_queued_per_store", defaultValue: -1, range: 0 ... 1024) {
            case let .value(parsed):
                maxQueuedPerStore = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queued_per_store` must be an integer between 0 and 1024.")
            }

            let maxQueuedGlobally: Int
            switch debugBoundedInt(arguments, "max_queued_global", defaultValue: -1, range: 0 ... 4096) {
            case let .value(parsed):
                maxQueuedGlobally = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queued_global` must be an integer between 0 and 4096.")
            }

            let maxQueueWaitMilliseconds: Int
            switch debugBoundedInt(arguments, "max_queue_wait_ms", defaultValue: 0, range: 100 ... 60000) {
            case let .value(parsed):
                maxQueueWaitMilliseconds = parsed
            case .defaulted, .invalid:
                return debugDiagnosticsError(op: op, code: "invalid_params", message: "`max_queue_wait_ms` must be an integer between 100 and 60000.")
            }

            let configuration = StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.Configuration(
                fairSharePerStore: fairSharePerStore,
                maxBurstPerStore: maxBurstPerStore,
                globalCapacity: globalCapacity,
                maxQueuedPerStore: maxQueuedPerStore,
                maxQueuedGlobally: maxQueuedGlobally,
                maxQueueWait: .milliseconds(maxQueueWaitMilliseconds)
            )
            switch await StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.shared.configureForDebug(configuration) {
            case let .applied(snapshot):
                return debugDiagnosticsResult([
                    "ok": true,
                    "op": op,
                    "admission": snapshot.payload()
                ])
            case let .busy(snapshot):
                return debugDiagnosticsResult([
                    "ok": false,
                    "op": op,
                    "code": "admission_busy",
                    "error": "Read/search content-fetch admission configuration can only change while the coordinator is idle.",
                    "admission": snapshot.payload()
                ], isError: true)
            }
        }

        private func debugMCPReadSearchCaptureLabel(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let replacement = UnicodeScalar("_")
            let scalars = trimmed.unicodeScalars.map { scalar in
                allowed.contains(scalar) ? scalar : replacement
            }
            return String(String.UnicodeScalarView(scalars.prefix(64)))
        }
    }

    private extension StoreBackedWorkspaceSearchContentFetchAdmissionCoordinator.DebugSnapshot {
        func payload() -> [String: Any] {
            [
                "configuration": [
                    "fair_share_per_store": configuration.fairSharePerStore,
                    "max_burst_per_store": configuration.maxBurstPerStore,
                    "global_capacity": configuration.globalCapacity,
                    "max_queued_per_store": configuration.maxQueuedPerStore,
                    "max_queued_global": configuration.maxQueuedGlobally,
                    "max_queue_wait_ms": configuration.maxQueueWaitMilliseconds
                ],
                "idle": isIdle,
                "lane_count": laneCount,
                "global_active_count": globalActiveCount,
                "global_queued_count": globalQueuedCount,
                "overload_count": overloadCount,
                "wait_expiry_count": waitExpiryCount,
                "queued_cancellation_count": queuedCancellationCount,
                "lane_loads": laneLoads.map { laneLoad in
                    [
                        "store_active_count": laneLoad.activeCount,
                        "store_queued_count": laneLoad.queuedCount,
                        "queued_search_count": laneLoad.queuedSearchCount
                    ]
                }
            ]
        }
    }

    private extension StoreBackedWorkspaceSearchAdmissionCoordinator.DebugSnapshot {
        func payload() -> [String: Any] {
            [
                "configuration": [
                    "per_store_capacity": configuration.perStoreCapacity,
                    "global_capacity": configuration.globalCapacity,
                    "max_queued_per_store": configuration.maxQueuedPerStore,
                    "max_queued_global": configuration.maxQueuedGlobally,
                    "max_queue_wait_ms": configuration.maxQueueWaitMilliseconds
                ],
                "idle": isIdle,
                "lane_count": laneCount,
                "global_active_count": globalActiveCount,
                "global_queued_count": globalQueuedCount,
                "overload_count": overloadCount,
                "wait_expiry_count": waitExpiryCount,
                "queued_cancellation_count": queuedCancellationCount,
                "lane_loads": laneLoads.map { laneLoad in
                    [
                        "store_active_count": laneLoad.activeCount,
                        "store_queued_count": laneLoad.queuedCount
                    ]
                }
            ]
        }
    }
#endif
