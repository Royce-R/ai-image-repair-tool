# AI 图片修复工具

这个工具用于把 AI 生成的图片批量转换成可在 PowerPoint 里手动修复的模板，并可选导出 SVG。它不依赖 OCR 识别文字内容，而是尽量检测图片里的文字区域，生成可编辑文本框、原图参考层和扣字底图，方便你在 PPT 中按原图手动改字。

## 快速开始

生成可编辑 PowerPoint 模板：

```powershell
.\ImageRepairTool.ps1 -Input .\resource -Output .\output -Target ppt -ReferenceSlides
```

处理单张图片：

```powershell
.\ImageRepairTool.ps1 -Input .\resource\example.png -Output .\output -Target ppt -ReferenceSlides
```

只导出 SVG：

```powershell
.\ImageRepairTool.ps1 -Input .\resource -Output .\output -Target svg -SvgMode embedded
```

同时导出 PPT 和 SVG：

```powershell
.\ImageRepairTool.ps1 -Input .\resource -Output .\output -Target both -ReferenceSlides -SvgMode embedded
```

## 输出目录

- `output/ppt/combined_editable_text_layer.pptx`：包含所有图片的总 PPT。
- `output/ppt/per_image/*.pptx`：每张图片一个单独 PPT。
- `output/ppt/cleaned/*.text_removed.png`：扣掉检测文字后的底图。
- `output/ppt/preview/*`：PPT 渲染预览图。
- `output/svg/embedded/*.svg`：视觉保持最准确的嵌入式 SVG。
- `output/svg/traced/*.svg`：启用描摹时生成的近似矢量 SVG。

## PowerPoint 编辑方式

推荐使用 `-ReferenceSlides`。每张源图会生成两页：

- 原图参考页：只放原始图片，用来查看原文。
- 可编辑页：包含 `01_original_reference`、`02_cleaned_text_removed` 和 `03_text_001...` 图层。

在 PowerPoint 里打开“选择窗格”。隐藏 `02_cleaned_text_removed` 可以看到下方原图文字，显示它则回到干净底图上编辑。`03_text_001...` 是可编辑文本框，通常按从上到下的顺序排列。

## 常用参数

- `-Input`：输入图片文件或图片文件夹。
- `-Output`：输出目录。
- `-Target ppt|svg|both`：选择导出 PPT、SVG 或两者都导出。
- `-ReferenceSlides`：为每张图额外生成原图参考页，推荐开启。
- `-TemplateMode dual|mimic|guide`：PPT 模板模式，默认 `dual`。
- `-Placeholder "文字"`：设置文本框占位文字。
- `-AutoPlaceholder`：用长度更接近原文字段的占位符。
- `-SvgMode both|embedded|trace`：SVG 导出模式。

## 打包发布

生成可分发目录和 zip：

```powershell
.\package_tool.ps1
```

打包结果：

- `dist/ai-image-repair-tool/`
- `dist/ai-image-repair-tool.zip`

把 zip 解压后，用户在解压目录里运行 `ImageRepairTool.ps1` 即可。

## 运行依赖

- PowerShell 5+ 或 PowerShell 7+。
- Python，并安装 NumPy。
- Node.js。
- ImageMagick。
- PowerPoint 导出依赖 Codex presentations 插件中的 artifact tool。脚本会自动查找；如果自动查找失败，可以通过 `-SkillDir` 手动指定 presentations skill 目录。

## 注意事项

- 工具不会 OCR 原图文字，所以不会自动填入真实文字。
- `cleaned` 底图是基于检测区域和背景色采样生成的，不是真正的智能修图。
- 复杂背景、装饰图标或非常小的文字可能会误检或漏检，需要在 PPT 中手动调整。
- 如果检测框太少，可尝试调大 `-LineGap` 或 `-VerticalGap`。
- 如果检测框太多，可尝试降低 `-DarkThreshold`、`-ColoredThreshold` 或 `-MaxBoxes`。
