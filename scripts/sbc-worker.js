"use strict";
const fs = require("fs");
const modulePath = process.argv[2];
if (!modulePath) process.exit(2);
const mod = require(modulePath);
if (typeof mod.init === "function") mod.init();
let pending = Buffer.alloc(0);
function consume() {
  while (pending.length >= 69) {
    const packet = pending.subarray(0, 69); pending = pending.subarray(69);
    const pcm = Buffer.alloc(160);
    const out = Buffer.alloc(480);
    for (let i = 0; i < 3; i++) {
      const frame = packet.subarray(i * 23, i * 23 + 23);
      if (frame[0] !== 0xad || frame[1] !== 0x31 || frame[2] !== 0x0c) process.exit(3);
      const result = mod.decode(frame, 23, pcm);
      if (!Number.isInteger(result) || result < 0) process.exit(3);
      // 厂商模块将 PCM 写入传入缓冲区；每帧固定 80 个 Int16 样本。
      pcm.copy(out, i * 160, 0, 160);
    }
    process.stdout.write(out);
  }
}
process.stdin.on("data", chunk => { pending = Buffer.concat([pending, chunk]); consume(); });
