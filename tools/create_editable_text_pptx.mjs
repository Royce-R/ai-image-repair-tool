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

async function writeBlob(filePath, blob) {
  await fs.writeFile(filePath, new Uint8Array(await blob.arrayBuffer()));
}

async function addRepairSlide(presentation, imageInfo, slideSize, options) {
  const slide = presentation.slides.add();
  slide.background.fill = "#f8fafc";

  const sourcePath = imageInfo.source;
  const bytes = await fs.readFile(sourcePath);
  const contentType = contentTypeFromBytes(bytes, sourcePath);
  const frame = fitContain(imageInfo.width, imageInfo.height, slideSize.width, slideSize.height);

  slide.images.add({
    blob: bytes,
    contentType,
    alt: imageInfo.name,
    fit: "contain",
    position: {
      left: frame.left,
      top: frame.top,
      width: frame.width,
      height: frame.height,
    },
  });

  for (const [index, box] of imageInfo.textBoxes.entries()) {
    const position = transformBox(box, frame);
    const shape = slide.shapes.add({
      geometry: "textbox",
      name: `${imageInfo.stem}_${box.id ?? `text_${index + 1}`}`,
      position,
      fill: "#ffffff00",
      line: {
        style: "solid",
        fill: options.guideColor,
        width: options.guideWidth,
      },
    });
    shape.text = options.placeholder;
    shape.text.style = {
      fontSize: Math.max(6, Math.min(54, box.fontSize * frame.scale)),
      color: options.placeholderColor,
      bold: false,
      fontFace: options.fontFace,
    };
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
  const placeholder = args.placeholder ?? " ";
  const guideColor = args["guide-color"] ?? "#2563eb";
  const placeholderColor = args["placeholder-color"] ?? "#dc2626";
  const guideWidth = Number.parseFloat(args["guide-width"] ?? "1");
  const fontFace = args["font-face"] ?? "Microsoft YaHei";

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
  };

  const combinedSize = combinedSlideSize(regions.images);
  const combined = Presentation.create({ slideSize: combinedSize });
  for (const imageInfo of regions.images) {
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
