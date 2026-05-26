const fs = require("fs");
const crypto = require("crypto");

const asarPath = process.argv[2];
const dryRun = process.argv.includes("--dry-run");

if (!asarPath) {
  console.error("Usage: node Patch-CodexAppServerRemoteControlArgWithIntegrity.js <app.asar> [--dry-run]");
  process.exit(2);
}

const oldText = "[`app-server`,`--analytics-default-enabled`]";
const helperText = "function $__RC(){return[`app-server`,`--analytics-default-enabled`,`--remote-control`]}";
const startText = "function qd(){let e=sf();";
const endText = "function Zd(e,t){";
const oldBytes = Buffer.from(oldText, "ascii");
const helperBytes = Buffer.from(helperText, "ascii");

function findAll(buffer, needle) {
  const positions = [];
  for (let index = 0; index <= buffer.length - needle.length; index += 1) {
    if (buffer[index] !== needle[0]) {
      continue;
    }
    let found = true;
    for (let needleIndex = 1; needleIndex < needle.length; needleIndex += 1) {
      if (buffer[index + needleIndex] !== needle[needleIndex]) {
        found = false;
        break;
      }
    }
    if (found) {
      positions.push(index);
      index += needle.length - 1;
    }
  }
  return positions;
}

function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function readAsarHeader(buffer) {
  const headerSize = buffer.readUInt32LE(4);
  const headerStringSize = buffer.readUInt32LE(12);
  const headerStart = 16;
  const dataStart = 8 + headerSize;
  const headerJson = buffer.slice(headerStart, headerStart + headerStringSize).toString("utf8");
  return {
    header: JSON.parse(headerJson),
    headerJson,
    headerSize,
    headerStringSize,
    headerStart,
    dataStart,
  };
}

function walkFiles(node, pathPrefix, dataStart, files) {
  if (!node || !node.files) {
    return;
  }

  for (const [name, entry] of Object.entries(node.files)) {
    const path = pathPrefix ? `${pathPrefix}/${name}` : name;
    if (entry.files) {
      walkFiles(entry, path, dataStart, files);
      continue;
    }
    if (entry.offset === undefined || entry.size === undefined) {
      continue;
    }
    const start = dataStart + Number(entry.offset);
    files.push({
      path,
      entry,
      start,
      end: start + Number(entry.size),
      size: Number(entry.size),
    });
  }
}

function findFileForPosition(files, position) {
  return files.find((file) => position >= file.start && position < file.end);
}

function recomputeIntegrity(buffer, file) {
  if (!file.entry.integrity) {
    throw new Error(`matched file has no integrity metadata: ${file.path}`);
  }

  const content = buffer.slice(file.start, file.end);
  const blockSize = Number(file.entry.integrity.blockSize || 4194304);
  const blocks = [];
  for (let offset = 0; offset < content.length; offset += blockSize) {
    blocks.push(sha256(content.slice(offset, Math.min(offset + blockSize, content.length))));
  }

  const oldBlockCount = Array.isArray(file.entry.integrity.blocks) ? file.entry.integrity.blocks.length : 0;
  if (oldBlockCount !== blocks.length) {
    throw new Error(`block count changed for ${file.path}: ${oldBlockCount} -> ${blocks.length}`);
  }

  file.entry.integrity.hash = sha256(content);
  file.entry.integrity.blocks = blocks;
}

const buffer = fs.readFileSync(asarPath);
const originalLength = buffer.length;
const info = readAsarHeader(buffer);

const files = [];
walkFiles(info.header, "", info.dataStart, files);

let oldPositions = findAll(buffer, oldBytes);
let helperPositions = findAll(buffer, helperBytes);

if (oldPositions.length === 0 && helperPositions.length === 1) {
  console.log("Patch already appears to be applied; refreshing integrity metadata.");
} else if (oldPositions.length !== 4) {
  throw new Error(`expected exactly 4 old app-server arg occurrences, found ${oldPositions.length}`);
} else {
  const latin1 = buffer.toString("latin1");
  const regionStart = latin1.indexOf(startText);
  if (regionStart < 0) {
    throw new Error("target region start was not found");
  }
  const regionEnd = latin1.indexOf(endText, regionStart);
  if (regionEnd < 0) {
    throw new Error("target region end was not found");
  }

  const oldRegion = latin1.slice(regionStart, regionEnd);
  const oldRegionDirectArgCount = (oldRegion.match(/\[`app-server`,`--analytics-default-enabled`\]/g) || []).length;
  if (oldRegionDirectArgCount !== 4) {
    throw new Error(`expected 4 direct app-server arg arrays inside target region, found ${oldRegionDirectArgCount}`);
  }

  let newRegion = oldRegion
    .replace("function Jd(", `${helperText}function Jd(`)
    .replaceAll(oldText, "$__RC()");

  if (newRegion.length > oldRegion.length) {
    throw new Error(`target region grew unexpectedly: ${oldRegion.length} -> ${newRegion.length}`);
  }
  newRegion = newRegion + " ".repeat(oldRegion.length - newRegion.length);
  if (newRegion.length !== oldRegion.length) {
    throw new Error("target region replacement length mismatch");
  }

  Buffer.from(newRegion, "latin1").copy(buffer, regionStart);
}

oldPositions = findAll(buffer, oldBytes);
helperPositions = findAll(buffer, helperBytes);

if (oldPositions.length !== 0 || helperPositions.length !== 1) {
  throw new Error(`unexpected counts after replacement: old=${oldPositions.length}, helper=${helperPositions.length}`);
}

const touchedByPath = new Map();
for (const position of helperPositions) {
  const file = findFileForPosition(files, position);
  if (!file) {
    throw new Error(`matched position is not inside an asar file entry: ${position}`);
  }
  touchedByPath.set(file.path, file);
}

for (const file of touchedByPath.values()) {
  recomputeIntegrity(buffer, file);
}

const newHeaderJson = JSON.stringify(info.header);
const newHeaderSize = Buffer.byteLength(newHeaderJson, "utf8");
if (newHeaderSize !== info.headerStringSize) {
  throw new Error(`header JSON byte length changed: ${info.headerStringSize} -> ${newHeaderSize}`);
}

Buffer.from(newHeaderJson, "utf8").copy(buffer, info.headerStart);

if (buffer.length !== originalLength) {
  throw new Error(`app.asar length changed: ${originalLength} -> ${buffer.length}`);
}

if (!dryRun) {
  fs.writeFileSync(asarPath, buffer);
}

const refreshed = [...touchedByPath.values()].map((file) => ({
  path: file.path,
  size: file.size,
  hash: file.entry.integrity.hash,
  blocks: file.entry.integrity.blocks.length,
}));

console.log(JSON.stringify({
  dryRun,
  headerSize: info.headerSize,
  headerStringSize: info.headerStringSize,
  dataStart: info.dataStart,
  oldOccurrences: oldPositions.length,
  helperOccurrences: helperPositions.length,
  refreshed,
}, null, 2));
