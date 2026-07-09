# GitHub Public Publishing Notes

This note is for preparing this repository as a public GitHub project.

## Recommended repository name

Use `ai-image-repair-tool`.

Why this name works:

- It matches the existing package name in `package_tool.ps1`.
- It is short enough to remember.
- It describes the actual workflow: repair an AI-generated or raster image by creating an editable PowerPoint template.
- It does not overpromise full automatic design reconstruction.

Alternative names if the first choice is unavailable:

- `editable-image-repair-pptx`
- `image-to-editable-ppt-template`
- `ppt-image-text-repair`
- `local-image-to-pptx-repair`

Suggested GitHub description:

> Local-first tool that converts raster images into PowerPoint repair templates with detected editable text layers, OCR placeholders, cleaned base images, and optional SVG export.

## Similar projects found

Search date: 2026-07-09.

The closest GitHub projects I found are:

- `laihenyi/NBLM2PPTX`: converts NotebookLM PDFs to PPTX with separated background images and editable text layers using Gemini AI.
- `JadeLiu-tech/px-image2pptx`: converts static images to editable PowerPoint slides using OCR, inpainting, and reconstruction.
- `JuniverseCoder/MinerU2PPT`: converts PDFs and images into editable PowerPoint files with AI-powered structure extraction.
- `winterdrive/OCR-Arcade`: React tool for scanned images and PDFs to editable PPTX using OCR and Fabric.js.
- `oresh123456/image_to_pptx`: converts image-only PowerPoint files into editable PPTX with OCR and inpainting.

This repository should avoid looking like a clone by emphasizing its own lane:

- Local-first PowerShell workflow instead of a browser app or cloud-first AI pipeline.
- Designed for manual PowerPoint repair, not fully automatic perfect reconstruction.
- Supports reference slides, cleaned base images, and predictable PowerPoint Selection Pane layer names.
- Can run OCR as best effort, but can also generate quiet placeholders with OCR disabled.
- Includes optional embedded/traced SVG export in the same workflow.
- Packages into a small distributable zip.

## Files that must not be published

Do not publish input images unless you own the rights and intentionally want them public.

The following paths are intentionally ignored:

- `resource/`
- `output/`, `output_*/`
- `tool_output/`, `tool_output_*/`, `tool_output_*.png`
- `ppt_editable_output/`, `ppt_editable_output_*/`
- `svg_output/`, `svg_output_*/`
- `dist/`
- `node_modules/`
- `.cache/`

Before pushing, run:

```powershell
git status --short --ignored -- resource
git rev-list --objects --all | Select-String -Pattern 'resource/|\.png$|\.pptx$|\.zip$'
```

Expected result:

- `resource/` may show as ignored with `!! resource/`.
- The `rev-list` scan should print nothing.

If the scan prints a copyrighted or private file, do not push. Remove it from history first.

## One-time GitHub setup

This machine currently did not show a `gh` command, so either install GitHub CLI or create the repository in the browser.

If GitHub CLI is available:

```powershell
gh auth login
gh repo create ai-image-repair-tool --public --source . --remote origin --push
```

If using the GitHub website:

1. Create a new public repository named `ai-image-repair-tool`.
2. Do not add a README, license, or `.gitignore` on GitHub because this repository already has them.
3. Add the remote locally:

```powershell
git remote add origin https://github.com/<your-user>/ai-image-repair-tool.git
git push -u origin master
```

Use a normal branch push. Do not use `git push --mirror`.

## Recommended repository topics

Add these GitHub topics:

- `powerpoint`
- `pptx`
- `ocr`
- `tesseract`
- `svg`
- `raster-to-svg`
- `image-repair`
- `editable-pptx`
- `powershell`

## Release checklist

Before the first public release:

1. Verify there are no copyrighted sample images in Git history.
2. Verify `README.md` starts with the actual user workflow, not marketing copy.
3. Verify `LICENSE` and `requirements.txt` are included.
4. Run a syntax check for Python scripts.
5. Run `package_tool.ps1` and confirm the zip does not include input images.
6. Push only the intended branch with `git push -u origin master`.
7. Create a GitHub release only after downloading the zip locally and checking its contents.

