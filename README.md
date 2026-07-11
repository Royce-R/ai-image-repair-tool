# AI 图片修复工具

这个工具用于把 AI 生成的图片批量转换成可在 PowerPoint 里手动修复的模板，并可选导出 SVG。它会尽量检测图片里的文字区域并调用 OCR 识别原文；识别不出来的位置用 `□` 这类安静占位符补足，方便你在 PPT 中按原图手动改字。

## 快速开始

先创建输入目录，并把你有权使用的图片放进去：

```powershell
New-Item -ItemType Directory -Force .\resource
```

检查当前环境是否能运行：

```powershell
.\ImageRepairTool.ps1 -Check -Input .\resource -Target both
```

生成可编辑 PowerPoint 模板：

```powershell
.\ImageRepairTool.ps1 -Input .\resource -Output .\output -Target ppt -ReferenceSlides
```

如果要检查文字框检测是否准确，可以额外生成带框预览：

```powershell
.\ImageRepairTool.ps1 -Input .\resource -Output .\output -Target ppt -ReferenceSlides -DebugPreview
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
- `output/ppt/debug/*.detected_boxes.svg`：开启 `-DebugPreview` 后生成的检测框预览。
- `output/svg/embedded/*.svg`：视觉保持最准确的嵌入式 SVG。
- `output/svg/traced/*.svg`：启用描摹时生成的近似矢量 SVG。

## PowerPoint 编辑方式

推荐使用 `-ReferenceSlides`。每张源图会生成两页：

- 原图参考页：只放原始图片，用来查看原文。
- 可编辑页：包含 `01_original_reference`、`02_cleaned_text_removed` 和 `03_text_001...` 图层。

在 PowerPoint 里打开“选择窗格”。隐藏 `02_cleaned_text_removed` 可以看到下方原图文字，显示它则回到干净底图上编辑。`03_text_001...` 是可编辑文本框，通常按从上到下的顺序排列。

## 常用参数

- `-Input`：输入图片文件或图片文件夹。
- `-Output`：输出目录，默认 `.\output`。
- `-Target ppt|svg|both`：选择导出 PPT、SVG 或两者都导出。
- `-Check`：只检查输入和依赖，不执行转换。
- `-ReferenceSlides`：为每张图额外生成原图参考页，推荐开启。
- `-DebugPreview`：生成带检测框的 SVG 预览，方便调参和排查误检。
- `-TemplateMode dual|mimic|guide`：PPT 模板模式，默认 `dual`。
- `-Placeholder "文字"`：设置文本框占位文字。
- `-AutoPlaceholder`：用长度更接近原文字段的占位符。
- `-OcrStrategy box|image|both`：OCR 策略，默认 `box`，逐框识别更准但更慢。
- `-OcrMode auto|off|tesseract`：OCR 开关，默认自动查找 Tesseract。
- `-FallbackGlyph "□"`：识别失败时使用的占位字符。
- `-SvgMode both|embedded|trace`：SVG 导出模式。
- `-Magick "路径"`：手动指定 ImageMagick 的 `magick.exe`，适合没有加入 PATH 的环境。

## 打包发布

生成可分发目录和 zip：

```powershell
.\package_tool.ps1
```

打包结果：

- `dist/ai-image-repair-tool/`
- `dist/ai-image-repair-tool.zip`

把 zip 解压后，用户在解压目录里运行 `ImageRepairTool.ps1` 即可。

如果要把项目发布为公开 GitHub 仓库，请先看 [PUBLISHING.md](PUBLISHING.md)，尤其是输入图片、输出文件和 Git 历史清理检查。

## 运行依赖

- PowerShell 5+ 或 PowerShell 7+。
- Python，并安装 NumPy。
- Node.js，并安装本项目的 Node 依赖。
- ImageMagick。
- Tesseract OCR，建议安装中文简体语言包 `chi_sim` 和英文 `eng`。
- PowerPoint 导出使用 `pptxgenjs`，不依赖 Codex presentations 插件。

安装依赖：

```powershell
python -m pip install -r requirements.txt
npm install
```

## 注意事项

- `resource/` 是本地输入目录，已被 `.gitignore` 忽略；不要把没有授权、含隐私或可能侵权的图片提交到公开仓库。
- OCR 是尽力识别，不保证完全正确，尤其是 AI 生成的小字、错字和复杂背景。
- `cleaned` 底图是基于检测区域和背景色采样生成的，不是真正的智能修图。
- 复杂背景、装饰图标或非常小的文字可能会误检或漏检，需要在 PPT 中手动调整。
- 如果觉得逐框 OCR 太慢，可以加 `-OcrStrategy image` 改用整图 OCR。
- 如果不想 OCR，只想生成占位模板，可以加 `-OcrMode off`。
- 如果检测框太少，可尝试调大 `-LineGap` 或 `-VerticalGap`。
- 如果检测框太多，可尝试降低 `-DarkThreshold`、`-ColoredThreshold` 或 `-MaxBoxes`。

## 许可证

本项目使用 MIT License。第三方工具和运行时依赖遵循各自许可证。
