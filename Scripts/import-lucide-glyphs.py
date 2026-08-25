#!/usr/bin/env python3
"""把 Lucide (ISC) 的描边 SVG 转成 SwiftUI Path 源码。

用法：python3 Scripts/import-lucide-glyphs.py <svg 目录> <输出 .swift>
Lucide 是纯描边字库：viewBox 0 0 24 24、根节点统一 fill=none /
stroke=currentColor / stroke-width=2 / 圆头圆角，子节点只有几何图元。
所以每个字形合成一条 Path 即可，线宽和端点样式由渲染侧统一给。

不认识的元素、带自己描边属性的子节点、带填充的子节点都会直接报错——
宁可导入失败，也不要悄悄画出一个和原图不一样的字形。
"""
import math
import pathlib
import re
import sys

TOKEN = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)")
ELEMENT = re.compile(r"<(path|circle|rect|line|polyline|polygon|ellipse)\b([^>]*?)/?>")
ATTR = re.compile(r'([a-zA-Z-]+)="([^"]*)"')
SVG_TAG = re.compile(r"<svg\b([^>]*)>")
NUMS = re.compile(r"-?\d*\.?\d+(?:[eE][-+]?\d+)?")

# 子节点只允许出现这些属性，其它（stroke-width / fill / opacity …）说明这个
# 字形不是「整体一个描边」，得人工确认后再决定怎么导。
ALLOWED_ATTRS = {
    "path": {"d"},
    "circle": {"cx", "cy", "r"},
    "ellipse": {"cx", "cy", "rx", "ry"},
    "rect": {"x", "y", "width", "height", "rx", "ry"},
    "line": {"x1", "y1", "x2", "y2"},
    "polyline": {"points"},
    "polygon": {"points"},
}


def parse_path(d):
    """返回 [(cmd, points)]，归一化为绝对 M/L/C/Z。"""
    tokens = []
    for m in TOKEN.finditer(d):
        tokens.append(m.group(1) if m.group(1) else float(m.group(2)))
    out = []
    i = 0
    cx = cy = sx = sy = 0.0
    last_cubic_ctrl = None
    last_quad_ctrl = None
    cmd = None
    while i < len(tokens):
        if isinstance(tokens[i], str):
            cmd = tokens[i]
            i += 1
            if cmd.upper() == "Z":
                out.append(("Z", []))
                cx, cy = sx, sy
                last_cubic_ctrl = last_quad_ctrl = None
                continue
        if cmd is None:
            raise SystemExit("路径以数字开头，缺少指令")
        rel = cmd.islower()
        C = cmd.upper()

        def num(n):
            nonlocal i
            vals = tokens[i:i + n]
            i += n
            return vals

        if C == "M":
            x, y = num(2)
            if rel:
                x += cx
                y += cy
            cx, cy, sx, sy = x, y, x, y
            out.append(("M", [x, y]))
            cmd = "l" if rel else "L"  # M 后的续参按 L 处理
            last_cubic_ctrl = last_quad_ctrl = None
        elif C == "L":
            x, y = num(2)
            if rel:
                x += cx
                y += cy
            cx, cy = x, y
            out.append(("L", [x, y]))
            last_cubic_ctrl = last_quad_ctrl = None
        elif C == "H":
            (x,) = num(1)
            if rel:
                x += cx
            cx = x
            out.append(("L", [x, cy]))
            last_cubic_ctrl = last_quad_ctrl = None
        elif C == "V":
            (y,) = num(1)
            if rel:
                y += cy
            cy = y
            out.append(("L", [cx, y]))
            last_cubic_ctrl = last_quad_ctrl = None
        elif C == "C":
            x1, y1, x2, y2, x, y = num(6)
            if rel:
                x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy
            out.append(("C", [x1, y1, x2, y2, x, y]))
            last_cubic_ctrl = (x2, y2)
            last_quad_ctrl = None
            cx, cy = x, y
        elif C == "S":
            x2, y2, x, y = num(4)
            if rel:
                x2 += cx; y2 += cy; x += cx; y += cy
            if last_cubic_ctrl is None:
                x1, y1 = cx, cy
            else:
                x1, y1 = 2 * cx - last_cubic_ctrl[0], 2 * cy - last_cubic_ctrl[1]
            out.append(("C", [x1, y1, x2, y2, x, y]))
            last_cubic_ctrl = (x2, y2)
            last_quad_ctrl = None
            cx, cy = x, y
        elif C in ("Q", "T"):
            if C == "Q":
                qx, qy, x, y = num(4)
                if rel:
                    qx += cx; qy += cy; x += cx; y += cy
            else:
                x, y = num(2)
                if rel:
                    x += cx; y += cy
                if last_quad_ctrl is None:
                    qx, qy = cx, cy
                else:
                    qx, qy = 2 * cx - last_quad_ctrl[0], 2 * cy - last_quad_ctrl[1]
            out.append(("C", [
                cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy),
                x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y),
                x, y,
            ]))
            last_quad_ctrl = (qx, qy)
            last_cubic_ctrl = None
            cx, cy = x, y
        elif C == "A":
            rx, ry, rot, large, sweep, x, y = num(7)
            if rel:
                x += cx
                y += cy
            out.extend(arc_to_cubics(cx, cy, rx, ry, rot, int(large), int(sweep), x, y))
            last_cubic_ctrl = last_quad_ctrl = None
            cx, cy = x, y
        else:
            raise SystemExit(f"未支持的指令 {cmd}")
    return out


def arc_to_cubics(x1, y1, rx, ry, rot_deg, large, sweep, x2, y2):
    """SVG 椭圆弧 → 三次贝塞尔（W3C 附录 B 的端点→圆心换算）。"""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [("L", [x2, y2])]
    phi = math.radians(rot_deg)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cosp * dx + sinp * dy
    y1p = -sinp * dx + cosp * dy
    rx, ry = abs(rx), abs(ry)
    lam = (x1p / rx) ** 2 + (y1p / ry) ** 2
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(max(0.0, num / den))
    if large == sweep:
        coef = -coef
    cxp = coef * rx * y1p / ry
    cyp = -coef * ry * x1p / rx
    cx = cosp * cxp - sinp * cyp + (x1 + x2) / 2
    cy = sinp * cxp + cosp * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        length = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1, min(1, dot / length)))
        return -a if ux * vy - uy * vx < 0 else a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    segments = max(1, math.ceil(abs(dtheta) / (math.pi / 2)))
    delta = dtheta / segments
    t = 4 / 3 * math.tan(delta / 4)
    result = []
    for k in range(segments):
        a1 = theta1 + k * delta
        a2 = a1 + delta

        def point(a):
            px, py = rx * math.cos(a), ry * math.sin(a)
            return (cosp * px - sinp * py + cx, sinp * px + cosp * py + cy)

        def deriv(a):
            px, py = -rx * math.sin(a), ry * math.cos(a)
            return (cosp * px - sinp * py, sinp * px + cosp * py)

        p1, p2 = point(a1), point(a2)
        d1, d2 = deriv(a1), deriv(a2)
        result.append(("C", [
            p1[0] + t * d1[0], p1[1] + t * d1[1],
            p2[0] - t * d2[0], p2[1] - t * d2[1],
            p2[0], p2[1],
        ]))
    return result


def swift_case(name):
    parts = name.split("-")
    return parts[0] + "".join(p.title() for p in parts[1:])


def check_root(svg_path, content):
    """确认根节点就是 Lucide 那套统一描边约定，不然后面合成一条 Path 是错的。"""
    m = SVG_TAG.search(content)
    if not m:
        raise SystemExit(f"{svg_path.name} 没有 <svg> 根节点")
    attrs = dict(ATTR.findall(m.group(1)))
    if attrs.get("viewBox") != "0 0 24 24":
        raise SystemExit(f"{svg_path.name} 的 viewBox 不是 0 0 24 24")
    if attrs.get("fill") != "none" or attrs.get("stroke") != "currentColor":
        raise SystemExit(f"{svg_path.name} 不是纯描边字形")
    if attrs.get("stroke-linecap") != "round" or attrs.get("stroke-linejoin") != "round":
        raise SystemExit(f"{svg_path.name} 的端点/拐角不是圆的，渲染侧的 StrokeStyle 对不上")
    return float(attrs.get("stroke-width", 2))


def read_glyph(svg_path):
    """返回归一化后的绘图指令序列（一个字形合成一条 Path）。"""
    content = svg_path.read_text()
    check_root(svg_path, content)
    cmds = []
    for m in ELEMENT.finditer(content):
        tag = m.group(1)
        attrs = dict(ATTR.findall(m.group(2)))
        extra = set(attrs) - ALLOWED_ATTRS[tag]
        if extra:
            raise SystemExit(f"{svg_path.name} 的 <{tag}> 带了额外属性 {sorted(extra)}，需人工确认")
        f = lambda k, d=0.0: float(attrs.get(k, d))  # noqa: E731
        if tag == "path":
            cmds.extend(parse_path(attrs["d"]))
        elif tag == "circle":
            cmds.append(("E", [f("cx"), f("cy"), f("r"), f("r")]))
        elif tag == "ellipse":
            cmds.append(("E", [f("cx"), f("cy"), f("rx"), f("ry")]))
        elif tag == "rect":
            rx = f("rx", f("ry"))
            ry = f("ry", rx)
            cmds.append(("R", [f("x"), f("y"), f("width"), f("height"), rx, ry]))
        elif tag == "line":
            cmds.append(("M", [f("x1"), f("y1")]))
            cmds.append(("L", [f("x2"), f("y2")]))
        else:  # polyline / polygon
            pts = [float(v) for v in NUMS.findall(attrs["points"])]
            if len(pts) < 4 or len(pts) % 2:
                raise SystemExit(f"{svg_path.name} 的 <{tag}> 顶点数不成对")
            cmds.append(("M", pts[0:2]))
            for k in range(2, len(pts), 2):
                cmds.append(("L", pts[k:k + 2]))
            if tag == "polygon":
                cmds.append(("Z", []))
    if not cmds:
        raise SystemExit(f"{svg_path.name} 里没有可用图元")
    return cmds


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    svg_dir = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    icons = {svg.stem: read_glyph(svg) for svg in sorted(svg_dir.glob("*.svg"))}
    if not icons:
        raise SystemExit(f"{svg_dir} 里没有 SVG")

    lines = [
        "// 本文件由 Scripts/import-lucide-glyphs.py 生成，勿手改。",
        "// 字形来源：Lucide <https://lucide.dev>（ISC License，Copyright (c) for",
        "// portions of Lucide are held by Cole Bemis 2013-2022 as part of Feather",
        "// (MIT)；其余版权归 Lucide Contributors 2022）。源 SVG 见 Support/Icons/lucide/。",
        "// 坐标空间 24×24、y 向下。原稿线宽 2、圆头圆角——线宽由渲染侧给，",
        "// 端点样式必须是 .round，否则和原图对不上。",
        "import SwiftUI",
        "",
        "/// 侧栏导航用的描边字形（Lucide）。",
        "enum LightAnchorNavGlyph: String, CaseIterable {",
    ]
    for name in icons:
        lines.append(f"    case {swift_case(name)}")
    lines += [
        "",
        "    /// 24×24 视框里的描边路径，用 StrokeStyle(lineCap: .round, lineJoin: .round) 画。",
        "    var path: Path {",
        "        var p = Path()",
        "        switch self {",
    ]
    for name, cmds in icons.items():
        lines.append(f"        case .{swift_case(name)}:")
        for cmd, v in cmds:
            if cmd == "M":
                lines.append(f"            p.move(to: CGPoint(x: {v[0]:.3f}, y: {v[1]:.3f}))")
            elif cmd == "L":
                lines.append(f"            p.addLine(to: CGPoint(x: {v[0]:.3f}, y: {v[1]:.3f}))")
            elif cmd == "C":
                lines.append(
                    f"            p.addCurve(to: CGPoint(x: {v[4]:.3f}, y: {v[5]:.3f}), "
                    f"control1: CGPoint(x: {v[0]:.3f}, y: {v[1]:.3f}), "
                    f"control2: CGPoint(x: {v[2]:.3f}, y: {v[3]:.3f}))"
                )
            elif cmd == "Z":
                lines.append("            p.closeSubpath()")
            elif cmd == "E":
                cx, cy, rx, ry = v
                lines.append(
                    f"            p.addEllipse(in: CGRect(x: {cx - rx:.3f}, y: {cy - ry:.3f}, "
                    f"width: {rx * 2:.3f}, height: {ry * 2:.3f}))"
                )
            elif cmd == "R":
                x, y, w, hh, rx, ry = v
                if rx or ry:
                    lines.append(
                        f"            p.addRoundedRect(in: CGRect(x: {x:.3f}, y: {y:.3f}, "
                        f"width: {w:.3f}, height: {hh:.3f}), "
                        f"cornerSize: CGSize(width: {rx:.3f}, height: {ry:.3f}), style: .circular)"
                    )
                else:
                    lines.append(
                        f"            p.addRect(CGRect(x: {x:.3f}, y: {y:.3f}, "
                        f"width: {w:.3f}, height: {hh:.3f}))"
                    )
        lines.append("            return p")
    lines += ["        }", "    }", "}"]
    out_path.write_text("\n".join(lines) + "\n")
    print(f"wrote {out_path} ({len(icons)} glyphs)")


if __name__ == "__main__":
    main()
