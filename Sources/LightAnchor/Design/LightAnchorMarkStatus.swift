import Foundation

/// 工作状态 → 标记形态的映射。
///
/// 单独成文件：`LightAnchorMark.swift` 只依赖 AppKit，`Scripts/make-brand-assets.swift`
/// 需要脱离应用类型单独编译它来产出图标资源。
extension LightAnchorMarkState {

    init(_ form: LightAnchorStatusDotForm) {
        switch form {
        case .active: self = .active
        case .returning: self = .returning
        case .waiting: self = .waiting
        // 菜单栏图标是 template 图像，拿不到「灰点」这一档颜色差别，
        // 结束和暂停一样落到空心环。
        case .paused, .ended: self = .idle
        }
    }

    init(episodeState: AttentionEpisodeState?) {
        guard let episodeState else {
            self = .idle
            return
        }
        self.init(LightAnchorStatusDotForm(episodeState))
    }
}
