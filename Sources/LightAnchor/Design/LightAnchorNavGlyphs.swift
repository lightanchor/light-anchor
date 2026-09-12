// 本文件由 Scripts/import-lucide-glyphs.py 生成，勿手改。
// 字形来源：Lucide <https://lucide.dev>（ISC License，Copyright (c) for
// portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather
// (MIT)；其余版权归 Lucide Contributors 2022）。源 SVG 见 Support/Icons/lucide/。
// 坐标空间 24×24、y 向下。原稿线宽 2、圆头圆角——线宽由渲染侧给，
// 端点样式必须是 .round，否则和原图对不上。
import SwiftUI

/// Lucide 描边字形库（侧栏导航、设置行等共用）。
enum LightAnchorNavGlyph: String, CaseIterable {
    case alarmClock
    case blocks
    case circleDashed
    case focus
    case messageCircle
    case notebookPen
    case rotateCcwClock
    case toolCase

    /// 24×24 视框里的描边路径，用 StrokeStyle(lineCap: .round, lineJoin: .round) 画。
    var path: Path {
        var p = Path()
        switch self {
        case .alarmClock:
            p.addEllipse(in: CGRect(x: 4.000, y: 5.000, width: 16.000, height: 16.000))
            p.move(to: CGPoint(x: 12.000, y: 9.000))
            p.addLine(to: CGPoint(x: 12.000, y: 13.000))
            p.addLine(to: CGPoint(x: 14.000, y: 15.000))
            p.move(to: CGPoint(x: 5.000, y: 3.000))
            p.addLine(to: CGPoint(x: 2.000, y: 6.000))
            p.move(to: CGPoint(x: 22.000, y: 6.000))
            p.addLine(to: CGPoint(x: 19.000, y: 3.000))
            p.move(to: CGPoint(x: 6.380, y: 18.700))
            p.addLine(to: CGPoint(x: 4.000, y: 21.000))
            p.move(to: CGPoint(x: 17.640, y: 18.670))
            p.addLine(to: CGPoint(x: 20.000, y: 21.000))
            return p
        case .blocks:
            p.move(to: CGPoint(x: 10.000, y: 22.000))
            p.addLine(to: CGPoint(x: 10.000, y: 7.000))
            p.addCurve(to: CGPoint(x: 9.000, y: 6.000), control1: CGPoint(x: 10.000, y: 6.448), control2: CGPoint(x: 9.552, y: 6.000))
            p.addLine(to: CGPoint(x: 4.000, y: 6.000))
            p.addCurve(to: CGPoint(x: 2.000, y: 8.000), control1: CGPoint(x: 2.895, y: 6.000), control2: CGPoint(x: 2.000, y: 6.895))
            p.addLine(to: CGPoint(x: 2.000, y: 20.000))
            p.addCurve(to: CGPoint(x: 4.000, y: 22.000), control1: CGPoint(x: 2.000, y: 21.105), control2: CGPoint(x: 2.895, y: 22.000))
            p.addLine(to: CGPoint(x: 16.000, y: 22.000))
            p.addCurve(to: CGPoint(x: 18.000, y: 20.000), control1: CGPoint(x: 17.105, y: 22.000), control2: CGPoint(x: 18.000, y: 21.105))
            p.addLine(to: CGPoint(x: 18.000, y: 15.000))
            p.addCurve(to: CGPoint(x: 17.000, y: 14.000), control1: CGPoint(x: 18.000, y: 14.448), control2: CGPoint(x: 17.552, y: 14.000))
            p.addLine(to: CGPoint(x: 2.000, y: 14.000))
            p.addRoundedRect(in: CGRect(x: 14.000, y: 2.000, width: 8.000, height: 8.000), cornerSize: CGSize(width: 1.000, height: 1.000), style: .circular)
            return p
        case .circleDashed:
            p.move(to: CGPoint(x: 10.100, y: 2.182))
            p.addCurve(to: CGPoint(x: 13.900, y: 2.182), control1: CGPoint(x: 11.355, y: 1.939), control2: CGPoint(x: 12.645, y: 1.939))
            p.move(to: CGPoint(x: 13.900, y: 21.818))
            p.addCurve(to: CGPoint(x: 10.100, y: 21.818), control1: CGPoint(x: 12.645, y: 22.061), control2: CGPoint(x: 11.355, y: 22.061))
            p.move(to: CGPoint(x: 17.609, y: 3.721))
            p.addCurve(to: CGPoint(x: 20.299, y: 6.421), control1: CGPoint(x: 18.670, y: 4.440), control2: CGPoint(x: 19.584, y: 5.357))
            p.move(to: CGPoint(x: 2.182, y: 13.900))
            p.addCurve(to: CGPoint(x: 2.182, y: 10.100), control1: CGPoint(x: 1.939, y: 12.645), control2: CGPoint(x: 1.939, y: 11.355))
            p.move(to: CGPoint(x: 20.279, y: 17.609))
            p.addCurve(to: CGPoint(x: 17.579, y: 20.299), control1: CGPoint(x: 19.560, y: 18.670), control2: CGPoint(x: 18.643, y: 19.584))
            p.move(to: CGPoint(x: 21.818, y: 10.100))
            p.addCurve(to: CGPoint(x: 21.818, y: 13.900), control1: CGPoint(x: 22.061, y: 11.355), control2: CGPoint(x: 22.061, y: 12.645))
            p.move(to: CGPoint(x: 3.721, y: 6.391))
            p.addCurve(to: CGPoint(x: 6.421, y: 3.701), control1: CGPoint(x: 4.440, y: 5.330), control2: CGPoint(x: 5.357, y: 4.416))
            p.move(to: CGPoint(x: 6.391, y: 20.279))
            p.addCurve(to: CGPoint(x: 3.701, y: 17.579), control1: CGPoint(x: 5.330, y: 19.560), control2: CGPoint(x: 4.416, y: 18.643))
            return p
        case .focus:
            p.addEllipse(in: CGRect(x: 9.000, y: 9.000, width: 6.000, height: 6.000))
            p.move(to: CGPoint(x: 3.000, y: 7.000))
            p.addLine(to: CGPoint(x: 3.000, y: 5.000))
            p.addCurve(to: CGPoint(x: 5.000, y: 3.000), control1: CGPoint(x: 3.000, y: 3.895), control2: CGPoint(x: 3.895, y: 3.000))
            p.addLine(to: CGPoint(x: 7.000, y: 3.000))
            p.move(to: CGPoint(x: 17.000, y: 3.000))
            p.addLine(to: CGPoint(x: 19.000, y: 3.000))
            p.addCurve(to: CGPoint(x: 21.000, y: 5.000), control1: CGPoint(x: 20.105, y: 3.000), control2: CGPoint(x: 21.000, y: 3.895))
            p.addLine(to: CGPoint(x: 21.000, y: 7.000))
            p.move(to: CGPoint(x: 21.000, y: 17.000))
            p.addLine(to: CGPoint(x: 21.000, y: 19.000))
            p.addCurve(to: CGPoint(x: 19.000, y: 21.000), control1: CGPoint(x: 21.000, y: 20.105), control2: CGPoint(x: 20.105, y: 21.000))
            p.addLine(to: CGPoint(x: 17.000, y: 21.000))
            p.move(to: CGPoint(x: 7.000, y: 21.000))
            p.addLine(to: CGPoint(x: 5.000, y: 21.000))
            p.addCurve(to: CGPoint(x: 3.000, y: 19.000), control1: CGPoint(x: 3.895, y: 21.000), control2: CGPoint(x: 3.000, y: 20.105))
            p.addLine(to: CGPoint(x: 3.000, y: 17.000))
            return p
        case .messageCircle:
            p.move(to: CGPoint(x: 2.992, y: 16.342))
            p.addCurve(to: CGPoint(x: 3.086, y: 17.509), control1: CGPoint(x: 3.139, y: 16.713), control2: CGPoint(x: 3.172, y: 17.119))
            p.addLine(to: CGPoint(x: 2.021, y: 20.799))
            p.addCurve(to: CGPoint(x: 2.314, y: 21.727), control1: CGPoint(x: 1.951, y: 21.138), control2: CGPoint(x: 2.062, y: 21.489))
            p.addCurve(to: CGPoint(x: 3.257, y: 21.967), control1: CGPoint(x: 2.565, y: 21.965), control2: CGPoint(x: 2.922, y: 22.056))
            p.addLine(to: CGPoint(x: 6.670, y: 20.969))
            p.addCurve(to: CGPoint(x: 7.769, y: 21.061), control1: CGPoint(x: 7.038, y: 20.896), control2: CGPoint(x: 7.419, y: 20.928))
            p.addCurve(to: CGPoint(x: 20.208, y: 17.713), control1: CGPoint(x: 12.178, y: 23.120), control2: CGPoint(x: 17.428, y: 21.707))
            p.addCurve(to: CGPoint(x: 19.028, y: 4.886), control1: CGPoint(x: 22.987, y: 13.720), control2: CGPoint(x: 22.489, y: 8.306))
            p.addCurve(to: CGPoint(x: 6.187, y: 3.863), control1: CGPoint(x: 15.567, y: 1.467), control2: CGPoint(x: 10.147, y: 1.035))
            p.addCurve(to: CGPoint(x: 2.992, y: 16.342), control1: CGPoint(x: 2.228, y: 6.692), control2: CGPoint(x: 0.880, y: 11.959))
            return p
        case .notebookPen:
            p.move(to: CGPoint(x: 13.400, y: 2.000))
            p.addLine(to: CGPoint(x: 6.000, y: 2.000))
            p.addCurve(to: CGPoint(x: 4.000, y: 4.000), control1: CGPoint(x: 4.895, y: 2.000), control2: CGPoint(x: 4.000, y: 2.895))
            p.addLine(to: CGPoint(x: 4.000, y: 20.000))
            p.addCurve(to: CGPoint(x: 6.000, y: 22.000), control1: CGPoint(x: 4.000, y: 21.105), control2: CGPoint(x: 4.895, y: 22.000))
            p.addLine(to: CGPoint(x: 18.000, y: 22.000))
            p.addCurve(to: CGPoint(x: 20.000, y: 20.000), control1: CGPoint(x: 19.105, y: 22.000), control2: CGPoint(x: 20.000, y: 21.105))
            p.addLine(to: CGPoint(x: 20.000, y: 12.600))
            p.move(to: CGPoint(x: 2.000, y: 6.000))
            p.addLine(to: CGPoint(x: 6.000, y: 6.000))
            p.move(to: CGPoint(x: 2.000, y: 10.000))
            p.addLine(to: CGPoint(x: 6.000, y: 10.000))
            p.move(to: CGPoint(x: 2.000, y: 14.000))
            p.addLine(to: CGPoint(x: 6.000, y: 14.000))
            p.move(to: CGPoint(x: 2.000, y: 18.000))
            p.addLine(to: CGPoint(x: 6.000, y: 18.000))
            p.move(to: CGPoint(x: 21.378, y: 5.626))
            p.addCurve(to: CGPoint(x: 21.928, y: 3.574), control1: CGPoint(x: 21.915, y: 5.089), control2: CGPoint(x: 22.124, y: 4.307))
            p.addCurve(to: CGPoint(x: 20.426, y: 2.072), control1: CGPoint(x: 21.731, y: 2.841), control2: CGPoint(x: 21.159, y: 2.269))
            p.addCurve(to: CGPoint(x: 18.374, y: 2.622), control1: CGPoint(x: 19.693, y: 1.876), control2: CGPoint(x: 18.911, y: 2.085))
            p.addLine(to: CGPoint(x: 13.364, y: 7.634))
            p.addCurve(to: CGPoint(x: 12.858, y: 8.488), control1: CGPoint(x: 13.126, y: 7.872), control2: CGPoint(x: 12.952, y: 8.165))
            p.addLine(to: CGPoint(x: 12.021, y: 11.358))
            p.addCurve(to: CGPoint(x: 12.147, y: 11.852), control1: CGPoint(x: 11.970, y: 11.533), control2: CGPoint(x: 12.018, y: 11.722))
            p.addCurve(to: CGPoint(x: 12.641, y: 11.978), control1: CGPoint(x: 12.277, y: 11.981), control2: CGPoint(x: 12.466, y: 12.029))
            p.addLine(to: CGPoint(x: 15.511, y: 11.141))
            p.addCurve(to: CGPoint(x: 16.365, y: 10.635), control1: CGPoint(x: 15.834, y: 11.047), control2: CGPoint(x: 16.127, y: 10.873))
            p.closeSubpath()
            return p
        case .rotateCcwClock:
            p.move(to: CGPoint(x: 3.000, y: 12.000))
            p.addCurve(to: CGPoint(x: 12.000, y: 21.000), control1: CGPoint(x: 3.000, y: 16.971), control2: CGPoint(x: 7.029, y: 21.000))
            p.addCurve(to: CGPoint(x: 21.000, y: 12.000), control1: CGPoint(x: 16.971, y: 21.000), control2: CGPoint(x: 21.000, y: 16.971))
            p.addCurve(to: CGPoint(x: 12.000, y: 3.000), control1: CGPoint(x: 21.000, y: 7.029), control2: CGPoint(x: 16.971, y: 3.000))
            p.addCurve(to: CGPoint(x: 5.260, y: 5.740), control1: CGPoint(x: 9.484, y: 3.009), control2: CGPoint(x: 7.069, y: 3.991))
            p.addLine(to: CGPoint(x: 3.000, y: 8.000))
            p.move(to: CGPoint(x: 3.000, y: 3.000))
            p.addLine(to: CGPoint(x: 3.000, y: 8.000))
            p.addLine(to: CGPoint(x: 8.000, y: 8.000))
            p.move(to: CGPoint(x: 12.000, y: 7.000))
            p.addLine(to: CGPoint(x: 12.000, y: 12.000))
            p.addLine(to: CGPoint(x: 16.000, y: 14.000))
            return p
        case .toolCase:
            p.move(to: CGPoint(x: 10.000, y: 15.000))
            p.addLine(to: CGPoint(x: 14.000, y: 15.000))
            p.move(to: CGPoint(x: 14.817, y: 10.995))
            p.addLine(to: CGPoint(x: 13.846, y: 9.545))
            p.addLine(to: CGPoint(x: 14.880, y: 8.313))
            p.addCurve(to: CGPoint(x: 15.059, y: 5.949), control1: CGPoint(x: 15.451, y: 7.649), control2: CGPoint(x: 15.523, y: 6.691))
            p.addCurve(to: CGPoint(x: 12.855, y: 5.075), control1: CGPoint(x: 14.595, y: 5.207), control2: CGPoint(x: 13.702, y: 4.853))
            p.addLine(to: CGPoint(x: 11.035, y: 5.439))
            p.addLine(to: CGPoint(x: 9.910, y: 3.885))
            p.addCurve(to: CGPoint(x: 7.847, y: 3.043), control1: CGPoint(x: 9.457, y: 3.212), control2: CGPoint(x: 8.642, y: 2.879))
            p.addCurve(to: CGPoint(x: 6.285, y: 4.633), control1: CGPoint(x: 7.052, y: 3.207), control2: CGPoint(x: 6.435, y: 3.835))
            p.addLine(to: CGPoint(x: 6.141, y: 6.550))
            p.addLine(to: CGPoint(x: 4.416, y: 6.976))
            p.addCurve(to: CGPoint(x: 3.004, y: 8.787), control1: CGPoint(x: 3.611, y: 7.222), control2: CGPoint(x: 3.046, y: 7.947))
            p.addCurve(to: CGPoint(x: 4.226, y: 10.732), control1: CGPoint(x: 2.961, y: 9.628), control2: CGPoint(x: 3.450, y: 10.406))
            p.addLine(to: CGPoint(x: 4.883, y: 11.002))
            p.move(to: CGPoint(x: 18.822, y: 10.995))
            p.addLine(to: CGPoint(x: 21.082, y: 5.615))
            p.addCurve(to: CGPoint(x: 21.081, y: 4.839), control1: CGPoint(x: 21.186, y: 5.367), control2: CGPoint(x: 21.186, y: 5.087))
            p.addCurve(to: CGPoint(x: 20.525, y: 4.297), control1: CGPoint(x: 20.976, y: 4.591), control2: CGPoint(x: 20.776, y: 4.395))
            p.addLine(to: CGPoint(x: 16.954, y: 2.900))
            p.addCurve(to: CGPoint(x: 15.673, y: 3.433), control1: CGPoint(x: 16.453, y: 2.704), control2: CGPoint(x: 15.887, y: 2.940))
            p.addLine(to: CGPoint(x: 14.749, y: 5.555))
            p.move(to: CGPoint(x: 4.000, y: 12.006))
            p.addCurve(to: CGPoint(x: 4.289, y: 11.297), control1: CGPoint(x: 3.998, y: 11.741), control2: CGPoint(x: 4.102, y: 11.486))
            p.addCurve(to: CGPoint(x: 4.994, y: 11.000), control1: CGPoint(x: 4.475, y: 11.108), control2: CGPoint(x: 4.729, y: 11.002))
            p.addLine(to: CGPoint(x: 19.000, y: 11.000))
            p.addCurve(to: CGPoint(x: 20.000, y: 12.000), control1: CGPoint(x: 19.552, y: 11.000), control2: CGPoint(x: 20.000, y: 11.448))
            p.addLine(to: CGPoint(x: 20.000, y: 19.000))
            p.addCurve(to: CGPoint(x: 18.000, y: 21.000), control1: CGPoint(x: 20.000, y: 20.105), control2: CGPoint(x: 19.105, y: 21.000))
            p.addLine(to: CGPoint(x: 6.000, y: 21.000))
            p.addCurve(to: CGPoint(x: 4.000, y: 19.000), control1: CGPoint(x: 4.895, y: 21.000), control2: CGPoint(x: 4.000, y: 20.105))
            p.closeSubpath()
            return p
        }
    }
}
