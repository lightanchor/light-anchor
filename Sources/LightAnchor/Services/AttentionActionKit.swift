import Foundation

enum AttentionAction: Equatable, Sendable {
    case captureText(String)
    case beginManualWaiting(String)
    case endCurrentEpisode
}

enum AttentionActionResult: Equatable, Sendable {
    case captured(UUID)
    case waitingStarted(UUID)
    case episodeEnded(UUID)
    case rejected(String)

    var message: String {
        switch self {
        case .captured:
            tr("saved_to_the_later_box")
        case .waitingStarted:
            tr("started_waiting")
        case .episodeEnded:
            tr("ended_the_current_work")
        case .rejected(let message):
            message
        }
    }
}

@MainActor
final class AttentionActionRouter {
    static let shared = AttentionActionRouter()

    private weak var workspace: AttentionWorkspace?

    func attach(workspace: AttentionWorkspace) {
        self.workspace = workspace
    }

    func perform(_ action: AttentionAction, now: Date = Date()) -> AttentionActionResult {
        guard let workspace else {
            return .rejected(tr("the_workspace_isn_t_ready_yet"))
        }

        switch action {
        case .captureText(let text):
            guard let capture = workspace.captureText(text, now: now) else {
                return .rejected(tr("nothing_saved_empty_text_or_unwritable_log"))
            }
            return .captured(capture.id)

        case .beginManualWaiting(let description):
            guard let episode = workspace.currentEpisode,
                  episode.state != .ended
            else {
                return .rejected(tr("no_work_in_progress_so_no_wait"))
            }
            guard let waiting = workspace.beginWaiting(
                episodeID: episode.id,
                kind: .manual,
                description: description,
                now: now
            ) else {
                return .rejected(tr("can_t_start_waiting_empty_or_unwritable"))
            }
            return .waitingStarted(waiting.id)

        case .endCurrentEpisode:
            guard let episode = workspace.currentEpisode,
                  episode.state != .ended,
                  workspace.endEpisode(episode.id, now: now)
            else {
                return .rejected(tr("there_is_no_work_to_end"))
            }
            return .episodeEnded(episode.id)
        }
    }
}
