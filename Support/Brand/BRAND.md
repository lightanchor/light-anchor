# 轻锚品牌资源

标记叫「蜜芽方块」：一块蜜色圆角软方墩，右上角浮着一枚蓝点。

- **蓝点**是产品的原子。界面里它标记当前注意力，标记里它是方墩顶起的那枚点。
- **方墩**恒定不变，负责识别——它让菜单栏里的那枚点不再是一个谁都能画的系统圆点。
- **状态由蓝点的形态承担**，不换隐喻、不换颜色（要求 6）：

  | 形态 | 状态 |
  | --- | --- |
  | 实心点 | 进行中 |
  | 双环（环 + 内点） | 准备返回 |
  | 点环 | 等待外部结果 |
  | 空心环 | 空闲 / 暂停 / 已结束 |

风格是纯平块面（参照 tty7 的做法）：三个平色、无渐变、无阴影；应用图标
≥48pt 会在方墩上用墨色挖出一张小脸（眼睛 + ω 嘴 + 腮红），16/32pt 不画脸。

## 颜色

| 角色 | 值 | 用处 |
| --- | --- | --- |
| 蓝点 | `#5BA7CE` | 点本体（主色） |
| 蜜色 | `#F3D07F` | 方墩 |
| 奶油底 | `#FDFAF4` | 应用图标底 |
| 墨色 | `#3B3644` | 脸、中文字标 |
| 次墨 | `#6E6879` | 英文副标 |
| 腮红 | `#E88E7A` 45% | 脸 |

菜单栏图标不上色：它是 template 图像，跟随菜单栏前景色、深色外观和高亮反色。

## 文件

| 文件 | 用处 |
| --- | --- |
| `AppIcon.icns` | 应用图标，`Scripts/build-release.sh` 会拷进 `Contents/Resources/` |
| `AppIcon-1024.png` | 上架用 1024 位图 |
| `lightanchor-mark.svg` | 标记单用（矢量） |
| `lightanchor-lockup-light.svg` | 横版 logo，浅色底（字形已转路径） |
| `lightanchor-lockup-dark.svg` | 横版 logo，深色底 |
| `brand-preview.png` | 一张总览审阅图 |

菜单栏图标没有资源文件：它由 `LightAnchorMark.statusItemImage(_:)` 在运行时绘制，
和这里的所有资源共用同一套几何。

## 改动方式

几何常量只有一处：`Sources/LightAnchor/Design/LightAnchorMark.swift`。改完跑

```text
Scripts/make-brand-assets.sh
```

重新生成上面所有文件，菜单栏图标会自动跟着变。`Tests/LightAnchorTests/BrandMarkTests.swift`
守着可读性：蓝点必须和方墩留出气口、四种状态在菜单栏尺寸下必须画出不同像素。

## 版式

横版 logo 以标记高度 H 为基准：标记与字标间距 0.42H，中文字号 0.62H
（PingFang SC Semibold），英文副标 0.17H（Helvetica Neue Medium，字距 0.038H）。
标记在浅色和深色底上都不换色。

最小使用尺寸：标记单用 16pt，横版 logo 24pt。再小就只用标记。

## 尚未覆盖

（2026-08-22 瘦身后只剩 macOS 主应用一个产物，品牌资源已全部覆盖。）
