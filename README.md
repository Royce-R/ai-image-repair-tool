# AI 生成图中文错字修正（可编辑 PPT）

Fix wrong/missing Chinese characters in AI-generated images via editable PowerPoint.

把 AI 生成图片里的中文错字、漏字、别字，转成可在 PowerPoint 里对照原图手动改正的可编辑模板。工具会检测文字区域、执行 OCR，并生成可编辑 PPT 文本框，方便你完成 OCR 后人工校对和改字补字。

本工具不是 AI 修图/重绘，不做 image inpainting、photo restoration、去模糊或超分，也不会自动替你改正文字；它生成可编辑文字层，让你在 PowerPoint 里对照原图手动修正 wrong/missing Chinese characters。

适用场景：AI 生成图片、海报、标题图、说明文字中出现的中文错字、漏字、别字，需要保留原图视觉并用 editable PowerPoint text boxes 手动校对。

## 快速开始

最简单的方式：

1. 把图片或图片文件夹拖到 `RepairImage.cmd` 上。
2. 等工具跑完。
3. 打开自动弹出的结果文件夹，看 `START_HERE.txt`。

也可以双击 `RepairImage.cmd`，它会处理默认的 `resource/` 文件夹。

命令行用户可以这样用：

```powershell
.\ImageRepairTool.ps1 ".\resource\example.png"
```

查看内置帮助：

```powershell
.\ImageRepairTool.ps1 -Help
```

检查当前环境是否能运行：

```powershell
.\ImageRepairTool.ps1 -Check -Input ".\resource"
```

转换一个文件夹：

```powershell
.\ImageRepairTool.ps1 -Input ".\resource" -Output ".\output"
```

如果不指定 `-Output`，结果会自动放进 `results/时间_图片名/`。完成后先打开：

- `START_HERE.txt`：告诉你应该先打开哪个文件。
- 单图输入默认生成 `editable_template.pptx`，里面先是原图参考页，再是可编辑页。
- 多图输入默认生成 `combined_editable_text_layer.pptx` 和 `editable_pptx/`。

## 输出模式

默认使用 `-OutputProfile simple`，只留下最终文件和 `START_HERE.txt`。

需要检查文字框检测是否准确时：

```powershell
.\ImageRepairTool.ps1 -Input ".\resource\example.png" -Output ".\output_debug" -OutputProfile debug
```

需要保留全部中间文件时：

```powershell
.\ImageRepairTool.ps1 -Input ".\resource" -Output ".\output_full" -OutputProfile full
```

## 输出目录

- `output/START_HERE.txt`：最先打开。
- `output/editable_template.pptx`：单图输入时的默认结果。
- `output/combined_editable_text_layer.pptx`：多图输入时的总 PPT。
- `output/editable_pptx/*.pptx`：多图输入时每张图一个 PPT。
- `output/ppt/...`：`debug` 或 `full` 模式下保留的完整工作文件。
- `output/svg/embedded/*.svg`：视觉保持最准确的嵌入式 SVG。
- `output/svg/traced/*.svg`：启用描摹时生成的近似矢量 SVG。

## PowerPoint 编辑方式

默认每张源图会生成两页：

- 原图参考页：只放原始图片，用来查看原文。
- 可编辑页：包含 `01_original_reference`、`02_cleaned_text_removed` 和 `03_text_001...` 图层。

在 PowerPoint 里打开“选择窗格”。隐藏 `02_cleaned_text_removed` 可以看到下方原图文字，显示它则回到干净底图上编辑。`03_text_001...` 是可编辑文本框，通常按从上到下的顺序排列。

如果图片文字特别密集，默认会自动跳过逐框 OCR，并把可编辑页切到“保留原图 + 蓝色选框”的引导模式。这时不会生成覆盖文字的白色 cleaned 底图，避免打开后只看到一堆白框。需要强制识别文字时再加 `-OcrMode tesseract`。

## 常用参数

- `-Input`：输入图片文件或图片文件夹。
- `-Output`：输出目录，默认 `.\output`。
- `-OutputProfile simple|debug|full`：控制输出多少，默认 `simple`。
- `-Target ppt|svg|both`：选择导出 PPT、SVG 或两者都导出。
- `-Check`：只检查输入和依赖，不执行转换。
- `-Help`：显示最短使用说明。

调参时再看这些：

- `-NoReferenceSlides`：不生成原图参考页，只保留可编辑页。
- `-DebugPreview`：生成带检测框的 SVG 预览。
- `-TemplateMode dual|mimic|guide`：PPT 模板模式，默认 `dual`。
- `-Placeholder "文字"`：设置文本框占位文字。
- `-AutoPlaceholder`：用长度更接近原文字段的占位符。
- `-OcrStrategy box|image|both`：OCR 策略，默认 `box`，逐框识别更准但更慢。
- `-OcrMode auto|off|tesseract`：OCR 开关，默认自动查找 Tesseract。
- `-OcrMaxBoxes 60`：默认超过 60 个文本框时自动跳过 OCR，并保留原图文字作为底图；用 `-OcrMode tesseract` 可强制 OCR。
- `-FallbackGlyph "□"`：识别失败时使用的占位字符。
- `-SvgMode both|embedded|trace`：SVG 导出模式。
- `-Magick "路径"`：手动指定 ImageMagick 的 `magick.exe`，适合没有加入 PATH 的环境。

## 打包发布

生成可分发目录和 zip：

```powershell
.\package_tool.ps1
```

打包结果：

- `dist/ai-image-chinese-text-fix-pptx/`
- `dist/ai-image-chinese-text-fix-pptx.zip`

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
- `cleaned` 底图是基于检测区域和背景色采样生成的，不是真正的 AI 修图、重绘或通用照片修复。
- 复杂背景、装饰图标或非常小的文字可能会误检或漏检，需要在 PPT 中手动调整。
- 如果觉得逐框 OCR 太慢，可以加 `-OcrStrategy image` 改用整图 OCR。
- 如果不想 OCR，只想生成占位模板，可以加 `-OcrMode off`。
- 如果检测框太少，可尝试调大 `-LineGap` 或 `-VerticalGap`。
- 如果文字和边框、箭头线粘在一起导致漏检，可调 `-LineSuppressionLength`；默认 `0` 表示按图像尺寸自动抑制长直线，传负数可关闭。
- 如果检测框太多，可尝试降低 `-DarkThreshold`、`-ColoredThreshold` 或 `-MaxBoxes`。

## 许可证

本项目使用 MIT License。第三方工具和运行时依赖遵循各自许可证。
