import Combine
import Foundation

@MainActor
final class WorkspaceRuntime: ObservableObject {
    private weak var workspace: AttentionWorkspace?
    private var maintenanceTask: Task<Void, Never>?
    private let interval: Duration

    init(workspace: AttentionWorkspace, interval: Duration = .seconds(5)) {
        self.workspace = workspace
        self.interval = interval
    }

    deinit {
        maintenanceTask?.cancel()
    }

    func start() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { @MainActor [weak self] in
            self?.workspace?.runBackgroundMaintenance()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self?.interval ?? .seconds(5))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.workspace?.runBackgroundMaintenance()
            }
        }
    }

    func stop() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        workspace?.stopBackgroundMaintenance()
    }
}
