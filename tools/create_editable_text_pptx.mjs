import fs from "node:fs/promises";
import path from "node:path";

import { Presentation, PresentationFile } from "@oai/artifact-tool";

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--")) {
      throw new Error(`Unexpected positional argument: ${key}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      args[key.slice(2)] = true;
      continue;
    }
    args[key.slice(2)] = value;
    index += 1;
  }
  return args;
}

function requireArg(args, key) {
  const value = args[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Missing required --${key}`);
  }
  return value;
}

function contentTypeFromBytes(bytes, fileName) {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47
  ) {
    return "image/png";
  }
  if (bytes.length >= 12 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") {
    return "image/webp";
  }
  const ext = path.extname(fileName).toLowerCase();
  if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
  if (ext === ".png") return "image/png";
  if (ext === ".webp") return "image/webp";
  return "image/png";
}

function safeName(value) {
  return String(value).replace(/[<>:"/\\|?*\x00-\x1f]/g, "_");
}

function fitContain(sourceWidth, sourceHeight, slideWidth, slideHeight) {
  const scale = Math.min(slideWidth / sourceWidth, slideHeight / sourceHeight);
  const width = sourceWidth * scale;
  const height = sourceHeight * scale;
  return {
    left: (slideWidth - width) / 2,
    top: (slideHeight - height) / 2,
    width,
    height,
    scale,
  };
}

function transformBox(box, frame) {
  return {
    left: frame.left + box.left * frame.scale,
    top: frame.top + box.top * frame.scale,
    width: box.width * frame.scale,
    height: box.height * frame.scale,
  };
}

function resolvePlaceholder(box, options) {
  if (options.placeholder === "__AUTO__" || options.placeholder === "__OCR__") {
    return box.ocrText || box.style?.templateText || "□";
  }
  return options.placeholder;
}

function transparentColor() {
  return "#ffffff00";
}

async function writeBlob(filePath, blob) {
  await fs.writeFile(filePath, new Uint8Array(await blob.arrayBuffer()));
}

async function addReferenceSlide(presentation, imageInfo, slideSize) {
  const slide = presentation.slides.add();
  slide.background.fill = "#f8fafc";
  const sourcePath = imageInfo.source;
  const bytes = await fs.readFile(sourcePath);
  const frame = fitContain(imageInfo.width, imageInfo.height, slideSize.width, slideSize.height);
  slide.images.add({
    blob: bytes,
    contentType: contentTypeFromBytes(bytes, sourcePath),
    alt: `01 original reference ${imageInfo.name}`,
    fit: "contain",
    position: {
      left: frame.left,
      top: frame.top,
      width: frame.width,
      height: frame.height,
    },
  });
  return slide;
}

async function addRepairSlide(presentation, imageInfo, slideSize, options) {
  const slide = presentation.slides.add();
  slide.background.fill = "#f8fafc";

  const sourcePath = imageInfo.source;
  const bytes = await fs.readFile(sourcePath);
  const contentType = contentTypeFromBytes(bytes, sourcePath);
  const frame = fitContain(imageInfo.width, imageInfo.height, slideSize.width, slideSize.height);
  const imagePosition = {
    left: frame.left,
    top: frame.top,
    width: frame.width,
    height: frame.height,
  };

  slide.images.add({
    blob: bytes,
    contentType,
    alt: imageInfo.name,
    name: `01_original_reference_${imageInfo.stem}`,
    fit: "contain",
    position: imagePosition,
  });

  const cleanedPath = imageInfo.cleanedSource;
  const hasCleanedImage = options.templateMode === "dual" && cleanedPath;
  if (hasCleanedImage) {
    const cleanedBytes = await fs.readFile(cleanedPath);
    slide.images.add({
      blob: cleanedBytes,
      contentType: contentTypeFromBytes(cleanedBytes, cleanedPath),
      alt: `${imageInfo.name} text removed`,
      name: `02_cleaned_text_removed_${imageInfo.stem}`,
      fit: "contain",
      position: imagePosition,
    });
  }

  for (const [index, box] of imageInfo.textBoxes.entries()) {
    const style = box.style ?? {};
    if (options.templateMode === "mimic" || (options.templateMode === "dual" && !hasCleanedImage)) {
      const maskBox = transformBox(box.mask ?? box, frame);
      slide.shapes.add({
        geometry: "rect",
        name: `02_mask_${imageInfo.stem}_${box.id ?? `text_${index + 1}`}`,
        position: maskBox,
        fill: style.backgroundColor ?? "#ffffff",
        line: { style: "solid", fill: "none", width: 0 },
      });
    }

    const position = transformBox(box, frame);
    const shape = slide.shapes.add({
      geometry: "textbox",
      name: `03_text_${imageInfo.stem}_${box.id ?? `text_${index + 1}`}`,
      position,
      fill: transparentColor(),
      line: {
        style: "solid",
        fill: options.guideWidth > 0 ? options.guideColor : "none",
        width: options.guideWidth,
      },
    });
    const fontSize = Math.max(5, Math.min(72, (style.fontSize ?? box.fontSize ?? 12) * frame.scale));
    const color = options.useSampledStyle ? (style.textColor ?? options.placeholderColor) : options.placeholderColor;
    const bold = options.useSampledStyle ? Boolean(style.bold) : false;
    shape.text = resolvePlaceholder(box, options);
    shape.text.style = {
      fontSize,
      color,
      bold,
      wrap: "none",
      autoFit: "shrinkText",
      alignment: style.alignment ?? "center",
      verticalAlignment: "top",
      insets: { left: 0, right: 0, top: 0, bottom: 0 },
    };
    shape.text.fontSize = fontSize;
    shape.text.color = color;
    shape.text.bold = bold;
    shape.text.typeface = options.fontFace;
    shape.text.alignment = style.alignment ?? "center";
    shape.text.verticalAlignment = "top";
    shape.text.wrap = "none";
    shape.text.autoFit = "shrinkText";
    shape.text.insets = { left: 0, right: 0, top: 0, bottom: 0 };
  }

  return slide;
}

function combinedSlideSize(images) {
  const landscapes = images.filter((item) => item.width >= item.height);
  const base = landscapes[0] ?? images[0];
  return { width: base.width, height: base.height };
}

async function exportDeckWithPreviews(presentation, pptxPath, previewDir, previewPrefix) {
  await fs.mkdir(path.dirname(pptxPath), { recursive: true });
  await fs.mkdir(previewDir, { recursive: true });

  for (const [index, slide] of presentation.slides.items.entries()) {
    const stem = `${previewPrefix}-slide-${String(index + 1).padStart(2, "0")}`;
    await writeBlob(
      path.join(previewDir, `${stem}.png`),
      await presentation.export({ slide, format: "png", scale: 1 }),
    );
  }

  const montage = await presentation.export({ format: "webp", montage: true, scale: 1 });
  await writeBlob(path.join(previewDir, `${previewPrefix}-montage.webp`), montage);

  const pptx = await PresentationFile.exportPptx(presentation);
  await pptx.save(pptxPath);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const regionsPath = path.resolve(requireArg(args, "regions"));
  const outputDir = path.resolve(args["output-dir"] ?? "ppt_editable_output");
  const placeholder = args.placeholder ?? "__AUTO__";
  const guideColor = args["guide-color"] ?? "#2563eb";
  const placeholderColor = args["placeholder-color"] ?? "#dc2626";
  const guideWidth = Number.parseFloat(args["guide-width"] ?? "0");
  const fontFace = args["font-face"] ?? "Microsoft YaHei";
  const templateMode = args["template-mode"] ?? "dual";
  const useSampledStyle = args["sampled-style"] !== "false";
  const referenceSlides = args["reference-slides"] === "true";

  const regions = JSON.parse(await fs.readFile(regionsPath, "utf8"));
  if (!Array.isArray(regions.images) || regions.images.length === 0) {
    throw new Error("No images found in text-region JSON.");
  }

  const options = {
    placeholder,
    guideColor,
    placeholderColor,
    guideWidth,
    fontFace,
    templateMode,
    useSampledStyle,
    referenceSlides,
  };

  const combinedSize = combinedSlideSize(regions.images);
  const combined = Presentation.create({ slideSize: combinedSize });
  for (const imageInfo of regions.images) {
    if (options.referenceSlides) {
      await addReferenceSlide(combined, imageInfo, combinedSize);
    }
    await addRepairSlide(combined, imageInfo, combinedSize, options);
  }

  const combinedPath = path.join(outputDir, "combined_editable_text_layer.pptx");
  await exportDeckWithPreviews(
    combined,
    combinedPath,
    path.join(outputDir, "preview"),
    "combined",
  );

  const perImageDir = path.join(outputDir, "per_image");
  for (const imageInfo of regions.images) {
    const exact = Presentation.create({
      slideSize: { width: imageInfo.width, height: imageInfo.height },
    });
    if (options.referenceSlides) {
      await addReferenceSlide(
        exact,
        imageInfo,
        { width: imageInfo.width, height: imageInfo.height },
      );
    }
    await addRepairSlide(
      exact,
      imageInfo,
      { width: imageInfo.width, height: imageInfo.height },
      options,
    );
    const filePath = path.join(perImageDir, `${safeName(imageInfo.stem)}.editable_text_layer.pptx`);
    await exportDeckWithPreviews(
      exact,
      filePath,
      path.join(outputDir, "preview"),
      safeName(imageInfo.stem),
    );
  }

  const summary = {
    combined: combinedPath,
    perImageDir,
    previewDir: path.join(outputDir, "preview"),
    images: regions.images.map((image) => ({
      name: image.name,
      width: image.width,
      height: image.height,
      textBoxes: image.textBoxes.length,
    })),
  };
  await fs.writeFile(path.join(outputDir, "ppt_summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
  console.log(`Combined PPTX: ${combinedPath}`);
  console.log(`Per-image PPTX: ${perImageDir}`);
  console.log(`Preview dir:    ${summary.previewDir}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
