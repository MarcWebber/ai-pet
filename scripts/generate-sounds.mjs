import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const outputDir = path.resolve(scriptDir, "../Resources/Sounds");
const sampleRate = 44_100;
const amplitude = 0.22;

const sounds = {
  "capture.wav": [
    { frequency: 460, duration: 0.09 },
    { frequency: 690, duration: 0.08 },
  ],
  "thinking.wav": [
    { frequency: 220, duration: 0.22 },
    { frequency: 260, duration: 0.16 },
  ],
  "answer.wav": [
    { frequency: 660, duration: 0.10 },
    { frequency: 990, duration: 0.14 },
  ],
  "error.wav": [
    { frequency: 240, duration: 0.14 },
    { frequency: 170, duration: 0.18 },
  ],
  "dock.wav": [{ frequency: 760, duration: 0.11 }],
};

function envelope(index, count) {
  const attack = Math.max(1, Math.floor(count * 0.12));
  const release = Math.max(1, Math.floor(count * 0.24));
  if (index < attack) return index / attack;
  if (index >= count - release) return (count - index - 1) / release;
  return 1;
}

function render(segments) {
  const samples = [];
  let phase = 0;
  for (const segment of segments) {
    const count = Math.floor(segment.duration * sampleRate);
    for (let index = 0; index < count; index += 1) {
      const sweep = 1 + 0.04 * (index / count);
      phase += (2 * Math.PI * segment.frequency * sweep) / sampleRate;
      const value =
        Math.sin(phase) * amplitude * envelope(index, count);
      samples.push(Math.max(-1, Math.min(1, value)));
    }
    const gap = Math.floor(sampleRate * 0.012);
    for (let index = 0; index < gap; index += 1) {
      samples.push(0);
    }
  }
  return samples;
}

function makeWave(samples) {
  const dataBytes = samples.length * 2;
  const buffer = Buffer.alloc(44 + dataBytes);
  buffer.write("RIFF", 0, "ascii");
  buffer.writeUInt32LE(36 + dataBytes, 4);
  buffer.write("WAVE", 8, "ascii");
  buffer.write("fmt ", 12, "ascii");
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36, "ascii");
  buffer.writeUInt32LE(dataBytes, 40);
  samples.forEach((sample, index) => {
    buffer.writeInt16LE(
      Math.round(sample * 32_767),
      44 + index * 2
    );
  });
  return buffer;
}

fs.mkdirSync(outputDir, { recursive: true });
for (const [fileName, segments] of Object.entries(sounds)) {
  fs.writeFileSync(
    path.join(outputDir, fileName),
    makeWave(render(segments))
  );
}
