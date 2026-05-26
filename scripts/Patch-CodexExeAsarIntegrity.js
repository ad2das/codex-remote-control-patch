const fs = require("fs");
const crypto = require("crypto");

const exePath = process.argv[2];
const asarPath = process.argv[3];
const dryRun = process.argv.includes("--dry-run");

if (!exePath || !asarPath) {
  console.error("Usage: node Patch-CodexExeAsarIntegrity.js <Codex.exe> <app.asar> [--dry-run]");
  process.exit(2);
}

function sha256Hex(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function readAsarHeaderString(buffer) {
  const headerStringSize = buffer.readUInt32LE(12);
  const headerStart = 16;
  return buffer.slice(headerStart, headerStart + headerStringSize);
}

const asar = fs.readFileSync(asarPath);
const headerHash = sha256Hex(readAsarHeaderString(asar));
const exe = fs.readFileSync(exePath);
const text = exe.toString("latin1");
const marker = '[{"file":"resources\\\\app.asar","alg":"SHA256","value":"';
const markerIndex = text.indexOf(marker);

if (markerIndex < 0) {
  throw new Error("Embedded AsarIntegrity marker was not found in Codex.exe");
}

const hashStart = markerIndex + marker.length;
const oldHash = text.slice(hashStart, hashStart + 64);

if (!/^[0-9a-f]{64}$/.test(oldHash)) {
  throw new Error(`Embedded AsarIntegrity hash has unexpected shape: ${oldHash}`);
}

if (oldHash !== headerHash) {
  Buffer.from(headerHash, "latin1").copy(exe, hashStart);
  if (!dryRun) {
    fs.writeFileSync(exePath, exe);
  }
}

console.log(JSON.stringify({
  dryRun,
  exePath,
  asarPath,
  markerIndex,
  oldHash,
  newHash: headerHash,
  changed: oldHash !== headerHash,
}, null, 2));
