/**
 * ios-image-shim.mjs —— iOS 无 sharp 环境的图片支持
 *
 * ## 为什么需要
 *
 * `@deepseek-ai/dsh-attachment-local` 把图片的准入、读取、请求版本生成
 * 全部交给 sharp（libvips 原生库）。iOS 包里 sharp 只有 JS 壳，
 * 没有 `@img/sharp-darwin-arm64` 原生二进制，于是：
 *
 * 1) **老对话重放必崩**：`dsh-llm-deepseek` 的 `prepareImages()` 会遍历
 *    历史里每一张图片的 attachmentId 并调用 `readImageRequest()`。任一图片
 *    触发 sharp 加载失败，整个 `request()` 抛错，被 `generate()` 统一包成
 *    `LlmError("DeepSeek Messages transport failed", "TRANSPORT")` ——
 *    前端显示 5/5 重试全部失败。表现为「纯文字新对话正常，老对话必崩」。
 *
 * 2) **新图上传失败**：`saveImages() → prepareImageFile() → detectImage()` /
 *    `normalizeImage()` 同样要 sharp。
 *
 * ## 怎么解决
 *
 * 用 Node `--import` 预加载本文件，在 dsh 主进程里替换
 * `LocalAttachmentStore` 的 5 个图片方法：
 *
 *   - `validateImage`    纯 JS 校验（格式/尺寸/像素上限）
 *   - `saveImage`        直存原始字节（不解码-缩放-重编码）
 *   - `saveImages`       批量版
 *   - `readImage`        读对象 + sha256 校验
 *   - `readImageRequest` 请求版本：直接返回原图（iOS 不做缩放）
 *
 * ## 与 yitchen/dsh-ios 的区别
 *
 * 那份是为 rc.1/rc.3 写的，patch 的是内部函数。rc.5 把
 * `LocalAttachmentStore` 和全部内部函数都 export 了，所以这里直接
 * 替换类方法，不碰私有符号 —— 升级 rc.x 时更稳。
 *
 * ## 约束
 *
 * - 只用 Node 内置模块
 * - 不改包内 node_modules 任何文件
 * - jitless 档可运行（无 WASM、无 JIT 依赖）
 */

import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const TAG = '[dsh-ios/image]';
const MAX_LOG = 240;

// 1x1 透明 PNG —— 对象缺失/损坏时的占位，保证老会话能继续
const FALLBACK_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z1ZkAAAAASUVORK5CYII=',
  'base64',
);

function log(msg) {
  try {
    process.stderr.write(`${TAG} ${msg}\n`);
  } catch {
    // stderr 不可写时静默
  }
}

function short(value) {
  return String(value?.message ?? value).split('\n')[0].slice(0, MAX_LOG);
}

// ============================================================================
// 纯 JS 图片头解析
// ============================================================================

/** 支持的媒体类型（与 rc.5 的 MEDIA_TYPES 对齐）。 */
const MEDIA_TYPES = {
  png: 'image/png',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
};

/**
 * 解析图片头，返回 { mediaType, width, height, animated, hasAlpha }。
 * 只读头部字节，不解码像素 —— 这正是替代 sharp.metadata() 的关键。
 */
function probeHeader(buf) {
  if (!buf || buf.length < 12) return null;

  // ---- PNG ----
  // 89 50 4E 47 0D 0A 1A 0A | IHDR
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
    if (buf.length < 33) return null;
    const width = buf.readUInt32BE(16);
    const height = buf.readUInt32BE(20);
    const bitDepth = buf[24];
    const colorType = buf[25];
    // colorType: 4 = grayscale+alpha, 6 = RGBA
    const hasAlpha = colorType === 4 || colorType === 6;
    // 动画 PNG：找 acTL 块
    let animated = false;
    const acTL = buf.indexOf(Buffer.from('acTL', 'ascii'));
    if (acTL > 0 && acTL < 4096) animated = true;
    return { mediaType: 'image/png', width, height, animated, hasAlpha, bitDepth };
  }

  // ---- JPEG ----
  // FF D8 FF
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
    let i = 2;
    let width = 0;
    let height = 0;
    let hasAlpha = false;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) { i++; continue; }
      const marker = buf[i + 1];
      // SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15（排除 DHT/JPG/DAC）
      const isSOF = (marker >= 0xc0 && marker <= 0xcf)
        && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
      if (isSOF) {
        height = buf.readUInt16BE(i + 5);
        width = buf.readUInt16BE(i + 7);
        const components = buf[i + 9];
        hasAlpha = components === 4; // CMYK/YCCK 之外的第 4 通道
        break;
      }
      // 跳过该段
      if (marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) {
        i += 2;
        continue;
      }
      const segLen = buf.readUInt16BE(i + 2);
      if (segLen < 2) break;
      i += 2 + segLen;
    }
    if (width === 0 || height === 0) return null;
    return { mediaType: 'image/jpeg', width, height, animated: false, hasAlpha, bitDepth: 8 };
  }

  // ---- GIF ----
  // "GIF87a" / "GIF89a"
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) {
    if (buf.length < 13) return null;
    const width = buf.readUInt16LE(6);
    const height = buf.readUInt16LE(8);
    const flags = buf[10];
    const hasAlpha = (flags & 0x01) !== 0;
    // 动画：数 NETSCAPE2.0 应用扩展或帧数 > 1
    let animated = buf.indexOf(Buffer.from('NETSCAPE2.0', 'ascii')) > 0;
    if (!animated) {
      // 粗略：出现多个 image descriptor (0x2C)
      let count = 0;
      for (let i = 13; i < Math.min(buf.length, 65536); i++) {
        if (buf[i] === 0x2c) { count++; if (count > 1) break; }
      }
      animated = count > 1;
    }
    return { mediaType: 'image/gif', width, height, animated, hasAlpha, bitDepth: 8 };
  }

  // ---- WebP ----
  // "RIFF" .... "WEBP"
  if (buf.length >= 30
      && buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46
      && buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) {
    const chunk = buf.toString('ascii', 12, 16);
    if (chunk === 'VP8 ') {
      // 有损：帧头在 26..29
      const width = buf.readUInt16LE(26) & 0x3fff;
      const height = buf.readUInt16LE(28) & 0x3fff;
      return { mediaType: 'image/webp', width, height, animated: false, hasAlpha: false, bitDepth: 8 };
    }
    if (chunk === 'VP8L') {
      // 无损：1 字节签名后 4 字节位打包
      const b = buf.readUInt32LE(21);
      const width = (b & 0x3fff) + 1;
      const height = ((b >> 14) & 0x3fff) + 1;
      const hasAlpha = ((b >> 28) & 0x1) === 1;
      return { mediaType: 'image/webp', width, height, animated: false, hasAlpha, bitDepth: 8 };
    }
    if (chunk === 'VP8X') {
      const flags = buf[20];
      const width = 1 + (buf[24] | (buf[25] << 8) | (buf[26] << 16));
      const height = 1 + (buf[27] | (buf[28] << 8) | (buf[29] << 16));
      const hasAlpha = (flags & 0x10) !== 0;
      const animated = (flags & 0x02) !== 0;
      return { mediaType: 'image/webp', width, height, animated, hasAlpha, bitDepth: 8 };
    }
    return null;
  }

  return null;
}

/** 读文件头（最多 64 KB，足够解析所有格式的尺寸）。 */
async function readHeader(path, signal) {
  const fh = await readFile(path, { signal });
  return fh.subarray(0, Math.min(fh.length, 65536));
}

function sha256Hex(data) {
  return createHash('sha256').update(data).digest('hex');
}

// ============================================================================
// 补丁应用
// ============================================================================

const PATCHED = Symbol.for('dsh.ios.imageSupport');

/**
 * 应用图片 shim。幂等：重复调用不会重复 patch。
 *
 * @param storeModule - `@deepseek-ai/dsh-attachment-local` 的模块命名空间
 * @param options.root - 附件对象根目录（通常 store.root）
 * @param options.limits - 图片限制
 */
export function applyImageShim(storeModule, options = {}) {
  const Store = storeModule.LocalAttachmentStore ?? storeModule.default;
  if (typeof Store !== 'function') {
    log('跳过：找不到 LocalAttachmentStore');
    return false;
  }
  if (Store[PATCHED]) {
    log('已打过补丁，跳过');
    return true;
  }

  const proto = Store.prototype;

  // ---- validateImage ----
  proto.validateImage = async function validateImage(input) {
    const data = input?.data ?? input;
    if (!data || data.length === 0) {
      throw makeError('Image data is empty.', 'INVALID_IMAGE');
    }
    const header = probeHeader(Buffer.from(data.buffer ?? data, data.byteOffset ?? 0, data.length));
    if (!header) {
      throw makeError('Unsupported or malformed image data.', 'INVALID_IMAGE');
    }
    const limits = this?.imageLimits ?? options.limits ?? {};
    checkLimits(header, limits);
    return undefined;
  };

  // ---- saveImage ----
  proto.saveImage = async function saveImage(input) {
    return this.saveImages([input]).then((r) => r[0]);
  };

  // ---- saveImages ----
  proto.saveImages = async function saveImages(inputs) {
    const out = [];
    for (const input of inputs) {
      const data = input?.data ?? input;
      const buf = Buffer.from(data.buffer ?? data, data.byteOffset ?? 0, data.length);
      const header = probeHeader(buf.subarray(0, Math.min(buf.length, 65536)));
      if (!header) throw makeError('Unsupported or malformed image data.', 'INVALID_IMAGE');
      checkLimits(header, this?.imageLimits ?? options.limits ?? {});

      const digest = sha256Hex(buf);
      const ref = {
        attachmentId: digest,
        sha256: digest,
        mediaType: header.mediaType,
        bytes: buf.length,
        width: header.width,
        height: header.height,
        animated: header.animated,
      };

      // 直存原始字节：不做解码-缩放-重编码
      const dest = imageObjectPath(this?.root ?? options.root, ref);
      await mkdir(dirname(dest), { recursive: true });
      await writeFile(dest, buf);

      out.push({ ref, data: new Uint8Array(buf) });
    }
    return out;
  };

  // ---- readImage ----
  proto.readImage = async function readImage(ref, signal) {
    signal?.throwIfAborted?.();
    const dest = imageObjectPath(this?.root ?? options.root, ref);
    let buf;
    try {
      buf = await readFile(dest, { signal });
    } catch (error) {
      signal?.throwIfAborted?.();
      if (error?.code === 'ENOENT') {
        throw makeError('Attachment object is missing.', 'ATTACHMENT_NOT_FOUND');
      }
      throw makeError('Unable to read image attachment.', 'ATTACHMENT_READ_FAILED', error);
    }
    // 完整性校验：与 rc.5 一致
    if (sha256Hex(buf) !== ref.sha256) {
      throw makeError('Stored attachment failed integrity verification.', 'ATTACHMENT_CORRUPT');
    }
    return { ref, data: new Uint8Array(buf) };
  };

  // ---- readImageRequest ----
  // 这是 TRANSPORT 的根因路径。iOS 不做请求版本缩放：
  // 直接返回原图，避免任何 sharp 依赖。
  proto.readImageRequest = async function readImageRequest(ref, target, signal) {
    try {
      return await this.readImage(ref, signal);
    } catch (error) {
      // 对象缺失/损坏时退化为 1x1 PNG，保证老会话能继续，
      // 而不是让整个 request 被打成 TRANSPORT。
      log(`readImageRequest 退化: ${short(error)} (ref=${ref?.attachmentId?.slice(0, 12)})`);
      return {
        ref: {
          ...ref,
          sha256: sha256Hex(FALLBACK_PNG),
          bytes: FALLBACK_PNG.length,
          width: 1,
          height: 1,
          mediaType: 'image/png',
          animated: false,
        },
        data: new Uint8Array(FALLBACK_PNG),
      };
    }
  };

  Store[PATCHED] = true;
  log('图片 shim 已应用（纯 JS 头解析，无 sharp）: validate/save/read/readRequest');
  return true;
}

// ============================================================================
// 辅助
// ============================================================================

function makeError(message, code, cause) {
  const err = new Error(message);
  err.code = code;
  if (cause) err.cause = cause;
  return err;
}

function checkLimits(header, limits) {
  const maxPixels = limits?.maxPixels;
  const maxDimension = limits?.maxDimension;
  if (maxPixels !== undefined && header.width * header.height > maxPixels) {
    throw makeError('Image exceeds the configured decoded-pixel limit.', 'IMAGE_TOO_MANY_PIXELS');
  }
  if (maxDimension !== undefined
      && Math.max(header.width, header.height) > maxDimension) {
    throw makeError('Image exceeds the configured per-side pixel limit.', 'IMAGE_DIMENSION_TOO_LARGE');
  }
}

/**
 * 对象存储路径。rc.5 用 `normalizedImagePath(root, ref)`，
 * 这里按同样的 content-addressed 布局拼：
 *   <root>/objects/<sha[0:2]>/<sha>
 */
function imageObjectPath(root, ref) {
  const base = root ?? '/var/jb/var/mobile/.dsh/attachments';
  const sha = ref?.sha256 ?? ref?.attachmentId ?? 'unknown';
  return join(base, 'objects', sha.slice(0, 2), sha);
}

// ============================================================================
// 自动应用（作为 --import 预加载时）
// ============================================================================

/**
 * 自动应用。
 *
 * 作为 `--import ./ios-image-shim.mjs` 预加载时，本模块在 dsh 主程序之前执行。
 * 注意：不能用 `process.argv.includes('ios-image-shim')` 判断 —— `--import`
 * 的路径不进 argv（argv 只有 bin.js 及其参数）。所以这里无条件尝试。
 *
 * 解析失败（NODE_PATH 未就绪等）时静默，交给 dsh-doctor 显式调用
 * applyImageShim() 兜底。
 */
async function autoApply() {
  try {
    const mod = await import('@deepseek-ai/dsh-attachment-local');
    applyImageShim(mod);
  } catch (error) {
    log(`自动应用跳过: ${short(error)}`);
  }
}

await autoApply();
