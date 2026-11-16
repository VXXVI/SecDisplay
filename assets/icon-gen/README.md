# SecDisplay 图标资产

## 最终交付

| 目录 | 方案 | 用途 |
| --- | --- | --- |
| `build/main/` | 主方案：双屏叠加 + 连接弧线 | 平面矢量，小尺寸可辨性最好 |
| `build/glass-a/` | 液态玻璃：暗色玻璃双屏，青色内透光 | 最贴近 Apple Liquid Glass，128px 以上效果最佳 |
| `build/glass-b/` | 液态玻璃：亮玻璃双屏 | 对比更强，但 16px 会糊成白块 |
| `build/alt-a/` | 备选 A：单向箭头 + 双屏 | 轮廓更硬，但 16px 下会糊成亮块 |

## v2 候选设计稿（待选定）

本地通过 Doubao 生图与 `build_icons.py` 产出了四套 v2 候选设计稿（存放于本地被 `.gitignore` 忽略的 `build/v2-*` 目录，待用户选定后再替换正式图标 `assets/app-icon/`）：

| 本地目录 | 方案 | 特点与处理方式 |
| --- | --- | --- |
| `build/v2-a/` | v2 候选 A：透视液态玻璃双屏 + ∞ 双向光弧 | 强纵深空间感，体现 Mac/Win 双向互通（直接裁切 squircle） |
| `build/v2-b/` | v2 候选 B：正向叠层液态玻璃 + ∞ 光弧 | 蓝青双色光环，贴近 Apple Liquid Glass 质感（直接裁切 squircle） |
| `build/v2-c/` | v2 候选 C：拉丝钛金属双屏 + 脉冲电弧 | 硬朗工程风，金青双脉冲象征零延迟雷电直连（内框裁切去重框后裁 squircle） |
| `build/v2-d/` | v2 候选 D：浅色磨砂极简 `< >` 双向符号 | 浅色桌面友好，小尺寸轮廓清晰（`--recenter` 居中重构） |

`build/v2-candidates-grid.png` 为上述四套 v2 设计稿的 2×2 对比预览图。

每个目录包含：

- `AppIcon-1024.png` 1024×1024 RGBA，squircle 外透明，可直接上架
- `AppIcon.icns` macOS 图标包，10 个尺寸
- `AppIcon.ico` Windows 图标包，16/24/32/48/64/128/256
- `png/` 512/256/128/64/32/16 六档 PNG
- `AppIcon-preview.png` 带外阴影的展示图，浅灰底

## 几何规范

- 画布 1024，图标主体 824×824 居中，四周留 100px
- 主体为超椭圆 n=5，等效圆角约 22.5% 主体宽
- 主体外完全透明，阴影交给 Finder / Dock 自己画

## 重新生成

```bash
python3 build_icons.py <源图.png> <输出目录> --name AppIcon
```

源图需要是满幅方形、无自带圆角、无外阴影的平面稿。`fullbleed/` 下是满足这个条件的原始生成图。

加 `--recenter` 会按亮部包围盒裁掉多余留白，把主体重新摆到画布正中并统一占幅，液态玻璃那几版是这么处理的。阈值默认 40，低于这个值会把背景的柔光也算进包围盒。

## 原始生成图

- `doubao_2026*.png` 主方案、备选 A、备选 B 的第一轮候选，带自带背景
- `fullbleed/` 满幅方形版本，供脚本二次加工
- `glass/` 液态玻璃风格候选
