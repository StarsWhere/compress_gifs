// Web Worker: runs ffmpeg.wasm to mirror compress_gifs.sh logic (simplified for browser)
// Use locally bundled ffmpeg to avoid CORS/MIME issues
import { FFmpeg } from './vendor/ffmpeg/index.js';

let currentTaskId = null;

const log = (msg) => {
  postMessage({ type: 'log', id: currentTaskId, payload: msg });
};

const ffmpeg = new FFmpeg();
ffmpeg.on('log', ({ type, message }) => {
  if (type === 'info' || type === 'fferr' || type === 'ffout' || type === 'warn') {
    log(message);
  }
});

const humanBytes = (b) => {
  if (b < 1024) return `${b}B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(2)}KB`;
  return `${(b / 1024 / 1024).toFixed(2)}MB`;
};

const buildProfiles = (maxW, preferKeep) => {
  const profiles = [];
  if (preferKeep) {
    profiles.push([maxW, 'keep', 256], [maxW, 'keep', 192], [maxW, 'keep', 160]);
  }
  profiles.push(
    [maxW, 18, 256],
    [maxW, 15, 256],
    [maxW, 12, 192],
    [960, 12, 192],
    [832, 10, 160],
    [768, 10, 128],
    [640, 8, 128],
    [576, 8, 96],
    [512, 8, 96],
    [448, 6, 80],
    [384, 5, 64],
    [320, 4, 64],
    [256, 4, 48],
    [256, 4, 32]
  );
  return profiles;
};

const loadFFmpeg = async () => {
  if (ffmpeg.loaded) return;
  const base = new URL('./vendor/ffmpeg/', self.location.href);
  await ffmpeg.load({
    coreURL: new URL('ffmpeg-core.js', base).href,
    wasmURL: new URL('ffmpeg-core.wasm', base).href,
    workerURL: new URL('ffmpeg-core.worker.js', base).href,
  });
};

const writeInput = async (name, buffer) => {
  await ffmpeg.writeFile(name, buffer);
};

const removeFileSafe = async (name) => {
  try {
    await ffmpeg.deleteFile(name);
  } catch (_) {
    /* ignore */
  }
};

const tryProfile = async (ctx, profileIdx, w, fps, colors) => {
  const { inputName, target, tolBytes, params, meta } = ctx;
  const palette = `palette_${profileIdx}.png`;
  const trial = `trial_${profileIdx}.gif`;

  const fpsFilter = fps === 'keep' ? '' : `fps=${fps},`;
  const timefix = ctx.timefixPrefix ? `${ctx.timefixPrefix},` : '';
  const scale = `scale=min(iw\\,${w}):-1:flags=lanczos`;
  const paletteFilter = `${timefix}${fpsFilter}${scale},palettegen=max_colors=${colors}:stats_mode=diff:reserve_transparent=1`;
  const useFilter = `[0:v]${timefix}${fpsFilter}${scale}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle`;

  try {
    await ffmpeg.exec([
      '-v',
      params.showFfmpeg ? 'info' : 'error',
      '-i',
      inputName,
      '-vf',
      paletteFilter,
      palette,
    ]);
    await ffmpeg.exec([
      '-v',
      params.showFfmpeg ? 'info' : 'error',
      '-i',
      inputName,
      '-i',
      palette,
      '-filter_complex',
      useFilter,
      '-loop',
      '0',
      trial,
    ]);
    const data = await ffmpeg.readFile(trial);
    const sz = data.length;
    const absDiff = sz > target ? sz - target : target - sz;
    const side = sz > target ? 1 : -1;
    if (params.verbose) {
      log(
        `档位#${profileIdx} 尝试: 宽=${w}, fps=${fps}, 色彩=${colors}, 输出=${humanBytes(sz)}, 偏差=${humanBytes(absDiff)} ${side > 0 ? '超标' : '达标'}`
      );
    }

    if (
      ctx.best.size === 0 ||
      absDiff < ctx.best.diff ||
      (absDiff === ctx.best.diff && side <= 0 && ctx.best.side > 0)
    ) {
      ctx.best = { data, size: sz, diff: absDiff, side, idx: profileIdx };
    }
    if (side <= 0 && absDiff <= tolBytes) {
      ctx.hit = true;
    }
    ctx.last = { size: sz, side };
    return { sz, absDiff, side };
  } catch (err) {
    log(`档位#${profileIdx} 失败：${err.message || err}`);
    return null;
  } finally {
    await removeFileSafe(palette);
    await removeFileSafe(trial);
  }
};

const processOne = async (payload) => {
  const { id, buffer, params, meta } = payload;
  currentTaskId = id;
  await loadFFmpeg();
  const inputName = `in_${id}.gif`;
  await writeInput(inputName, new Uint8Array(buffer));

  const target = params.maxMb * 1024 * 1024;
  const tolBytes = params.tolMb * 1024 * 1024;
  const maxW = params.maxW;

  const needSize = meta.size > target;
  const needScale = meta.width && meta.width > maxW;
  const needDur =
    meta.duration !== null &&
    (meta.duration < params.durMin - params.durEps || meta.duration > params.durMax + params.durEps);

  const ctx = {
    inputName,
    target,
    tolBytes,
    params,
    meta,
    timefixPrefix: '',
    best: { data: null, size: 0, diff: 0, side: 0, idx: -1 },
    hit: false,
    last: { size: 0, side: 0 },
  };

  log(
    `开始压缩：原始 ${humanBytes(meta.size)}，分辨率 ${meta.width || '?'}x${meta.height || '?'}，时长 ${
      meta.duration ? `${meta.duration.toFixed(2)}s` : '未知'
    }，目标上限 ${params.maxMb}MB，容差 ${params.tolMb}MB，最大宽度 ${maxW}px，模式 ${
      params.preferKeep ? '优先保帧间隔' : '标准'
    }`
  );

  if (meta.duration !== null && needDur) {
    const targetDur = Math.min(Math.max(meta.duration, params.durMin), params.durMax);
    const factor = targetDur / (meta.duration || targetDur || 0.001);
    ctx.timefixPrefix = `setpts=${factor.toFixed(6)}*PTS`;
    log(`调整时长：${meta.duration.toFixed(2)}s → ${targetDur.toFixed(2)}s (因 dur 范围限制)`);
  }

  if (!needSize && !needScale && !needDur) {
    const original = await ffmpeg.readFile(inputName);
    log('无需重新编码，直接复用原文件');
    return { buffer: original, hit: true, bestIdx: -1, note: 'copied' };
  }

  const preferKeep = (!needSize && needScale) || (!needSize && needDur) ? 1 : 0;
  const profiles = buildProfiles(maxW, preferKeep);

  // boundary trials
  await tryProfile(ctx, 0, ...profiles[0]);
  if (ctx.hit) return { buffer: ctx.best.data, hit: true, bestIdx: ctx.best.idx };

  if (profiles.length > 1) {
    const lastIdx = profiles.length - 1;
    await tryProfile(ctx, lastIdx, ...profiles[lastIdx]);
    if (ctx.hit) return { buffer: ctx.best.data, hit: true, bestIdx: ctx.best.idx };
  }

  if (profiles.length <= 2) {
    return { buffer: ctx.best.data || (await ffmpeg.readFile(inputName)), hit: ctx.hit, bestIdx: ctx.best.idx };
  }

  let l = 1;
  let r = profiles.length - 2;
  const maxIter = profiles.length * 2;
  let iter = 0;
  while (l <= r && iter < maxIter && !ctx.hit) {
    iter += 1;
    const mid = Math.floor((l + r) / 2);
    await tryProfile(ctx, mid, ...profiles[mid]);
    if (ctx.hit) break;
    if (ctx.last.size > target) l = mid + 1;
    else r = mid - 1;
  }

  if (ctx.best.data) {
    log(
      `最优候选：档位#${ctx.best.idx} 输出 ${humanBytes(ctx.best.size)}，偏差 ${humanBytes(
        ctx.best.diff
      )}，${ctx.hit ? '命中容差' : '未命中容差'}`
    );
  } else {
    log('未找到候选结果，回退原文件');
  }

  return { buffer: ctx.best.data || (await ffmpeg.readFile(inputName)), hit: ctx.hit, bestIdx: ctx.best.idx };
};

self.onmessage = async (event) => {
  const { type } = event.data;
  if (type === 'init') {
    try {
      await loadFFmpeg();
      postMessage({ type: 'ready' });
    } catch (err) {
      postMessage({ type: 'error', payload: `FFmpeg 加载失败：${err.message || err}` });
    }
    return;
  }

  if (type === 'compress') {
    const { id } = event.data;
    try {
      const result = await processOne(event.data);
      postMessage({ type: 'done', id, payload: result }, [result.buffer.buffer]);
    } catch (err) {
      postMessage({ type: 'error', id, payload: err.message || String(err) });
    } finally {
      await removeFileSafe(`in_${id}.gif`);
      currentTaskId = null;
    }
  }
};
