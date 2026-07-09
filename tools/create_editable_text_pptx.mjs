import fs from "node:fs/promises";
import path from "node:path";

import pptxgen from "pptxgenjs";

const PX_PER_INCH = 96;
const SLIDE_BACKGROUND = "F8FAFC";

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

function safeName(value) {
  return String(value).replace(/[<>:"/\\|?*\x00-\x1f]/g, "_");
}

function color(value, fallback = "000000") {
  const text = String(value ?? "").trim().replace(/^#/, "");
  if (/^[0-9a-fA-F]{6}$/.test(text)) {
    return text.toUpperCase();
  }
  if (/^[0-9a-fA-F]{8}$/.test(text)) {
    return text.slice(0, 6).toUpperCase();
  }
  return fallback;
}

function pointsToInches(value) {
  return value / PX_PER_INCH;
}

function pptPosition(position) {
  return {
    x: pointsToInches(position.left),
    y: pointsToInches(position.top),
    w: Math.max(pointsToInches(position.width), 0.01),
    h: Math.max(pointsToInches(position.height), 0.01),
  };
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

function createPresentation(slideSize) {
  const pptx = new pptxgen();
  const layoutName = `CUSTOM_${Math.round(slideSize.width)}_${Math.round(slideSize.height)}`;
  pptx.defineLayout({
    name: layoutName,
    width: pointsToInches(slideSize.width),
    height: pointsToInches(slideSize.height),
  });
  pptx.layout = layoutName;
  pptx.author = "AI Image Repair Tool";
  pptx.company = "AI Image Repair Tool";
  pptx.subject = "Editable image repair template";
  pptx.title = "Editable Image Repair Template";
  pptx.lang = "zh-CN";
  return pptx;
}

function addSlide(pptx) {
  const slide = pptx.addSlide();
  slide.background = { color: SLIDE_BACKGROUND };
  return slide;
}

function addImage(slide, imagePath, position, altText) {
  slide.addImage({
    path: imagePath,
    ...pptPosition(position),
    altText,
  });
}

async function addReferenceSlide(pptx, imageInfo, slideSize) {
  const slide = addSlide(pptx);
  const frame = fitContain(imageInfo.width, imageInfo.height, slideSize.width, slideSize.height);
  addImage(slide, imageInfo.source, frame, `01 original reference ${imageInfo.name}`);
}

async function addRepairSlide(pptx, imageInfo, slideSize, options) {
  const slide = addSlide(pptx);
  const frame = fitContain(imageInfo.width, imageInfo.height, slideSize.width, slideSize.height);
  const imagePosition = {
    left: frame.left,
    top: frame.top,
    width: frame.width,
    height: frame.height,
  };

  addImage(slide, imageInfo.source, imagePosition, imageInfo.name);

  const cleanedPath = imageInfo.cleanedSource;
  const hasCleanedImage = options.templateMode === "dual" && cleanedPath;
  if (hasCleanedImage) {
    addImage(slide, cleanedPath, imagePosition, `${imageInfo.name} text removed`);
  }

  for (const [index, box] of imageInfo.textBoxes.entries()) {
    const style = box.style ?? {};
    if (options.templateMode === "mimic" || (options.templateMode === "dual" && !hasCleanedImage)) {
      const maskBox = transformBox(box.mask ?? box, frame);
      const maskColor = color(style.backgroundColor, "FFFFFF");
      slide.addShape(pptx.ShapeType.rect, {
        ...pptPosition(maskBox),
        fill: { color: maskColor },
        line: { color: maskColor, transparency: 100 },
      });
    }

    const textPosition = transformBox(box, frame);
    const fontSize = Math.max(5, Math.min(72, (style.fontSize ?? box.fontSize ?? 12) * frame.scale));
    const textColor = options.useSampledStyle ? color(style.textColor, color(options.placeholderColor, "DC2626")) : color(options.placeholderColor, "DC2626");
    const guideColor = color(options.guideColor, "2563EB");
    const text = resolvePlaceholder(box, options) || "□";
    slide.addText(text, {
      ...pptPosition(textPosition),
      margin: 0,
      fontFace: options.fontFace,
      fontSize,
      color: textColor,
      bold: options.useSampledStyle ? Boolean(style.bold) : false,
      align: style.alignment ?? "center",
      valign: "top",
      fit: "shrink",
      breakLine: false,
      fill: { color: "FFFFFF", transparency: 100 },
      line: options.guideWidth > 0
        ? { color: guideColor, width: options.guideWidth }
        : { color: "FFFFFF", transparency: 100 },
      name: `03_text_${imageInfo.stem}_${box.id ?? `text_${index + 1}`}`,
    });
  }
}

function combinedSlideSize(images) {
  const landscapes = images.filter((item) => item.width >= item.height);
  const base = landscapes[0] ?? images[0];
  return { width: base.width, height: base.height };
}

async function writePresentation(pptx, pptxPath) {
  await fs.mkdir(path.dirname(pptxPath), { recursive: true });
  await pptx.writeFile({ fileName: pptxPath });
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
  const combined = createPresentation(combinedSize);
  for (const imageInfo of regions.images) {
    if (options.referenceSlides) {
      await addReferenceSlide(combined, imageInfo, combinedSize);
    }
    await addRepairSlide(combined, imageInfo, combinedSize, options);
  }

  const combinedPath = path.join(outputDir, "combined_editable_text_layer.pptx");
  await writePresentation(combined, combinedPath);

  const perImageDir = path.join(outputDir, "per_image");
  for (const imageInfo of regions.images) {
    const exactSize = { width: imageInfo.width, height: imageInfo.height };
    const exact = createPresentation(exactSize);
    if (options.referenceSlides) {
      await addReferenceSlide(exact, imageInfo, exactSize);
    }
    await addRepairSlide(exact, imageInfo, exactSize, options);
    const filePath = path.join(perImageDir, `${safeName(imageInfo.stem)}.editable_text_layer.pptx`);
    await writePresentation(exact, filePath);
  }

  const summary = {
    combined: combinedPath,
    perImageDir,
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
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
