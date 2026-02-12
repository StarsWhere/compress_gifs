const DEFAULT_PRESET = {
  id: 'wechat',
  name: '微信表情包',
  maxMb: 9,
  maxW: 1024,
  tolMb: 1,
  durMin: 0,
  durMax: 4,
  durEps: 0.02,
  preferKeep: true,
  verbose: false,
  showFfmpeg: false,
};

const PRESETS_KEY = 'gif_presets_v1';
const CURRENT_KEY = 'gif_current_preset';

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

const state = {
  presets: [],
  currentPresetId: DEFAULT_PRESET.id,
  tasks: new Map(), // id -> data
  workerReady: false,
  gifuct: null,
};

const worker = new Worker('./worker.js', { type: 'module' });

const logGlobal = (msg) => {
  const el = $('#log-output');
  const text = `[${new Date().toLocaleTimeString()}] ${msg}\n`;
  el.textContent += text;
  el.scrollTop = el.scrollHeight;
};

const humanBytes = (b) => {
  if (b < 1024) return `${b}B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(2)}KB`;
  return `${(b / 1024 / 1024).toFixed(2)}MB`;
};

const loadPresets = () => {
  const stored = localStorage.getItem(PRESETS_KEY);
  if (stored) {
    try {
      state.presets = JSON.parse(stored);
    } catch {
      state.presets = [DEFAULT_PRESET];
    }
  } else {
    state.presets = [DEFAULT_PRESET];
  }
  const cur = localStorage.getItem(CURRENT_KEY);
  if (cur && state.presets.find((p) => p.id === cur)) {
    state.currentPresetId = cur;
  } else {
    state.currentPresetId = DEFAULT_PRESET.id;
  }
};

const savePresets = () => {
  localStorage.setItem(PRESETS_KEY, JSON.stringify(state.presets));
  localStorage.setItem(CURRENT_KEY, state.currentPresetId);
};

const renderPresets = () => {
  const container = $('#preset-list');
  container.innerHTML = '';
  const tpl = $('#preset-item-tpl');
  state.presets.forEach((p) => {
    const node = tpl.content.cloneNode(true);
    node.querySelector('.title').textContent = p.name;
    node.querySelector('.meta').textContent = `${p.maxMb}MB · ${p.maxW}px · 容差${p.tolMb}MB · ${p.durMin}-${p.durMax}s`;
    node.querySelector('.use').onclick = () => {
      state.currentPresetId = p.id;
      savePresets();
      applyPreset(p);
      renderPresets();
    };
    node.querySelector('.del').onclick = () => {
      if (p.id === DEFAULT_PRESET.id) {
        alert('默认预设不可删除');
        return;
      }
      state.presets = state.presets.filter((x) => x.id !== p.id);
      if (state.currentPresetId === p.id) state.currentPresetId = DEFAULT_PRESET.id;
      savePresets();
      renderPresets();
    };
    if (p.id === state.currentPresetId) node.querySelector('.preset-item').classList.add('active');
    container.appendChild(node);
  });
};

const applyPreset = (preset) => {
  $('#max-mb').value = preset.maxMb;
  $('#max-w').value = preset.maxW;
  $('#tol-mb').value = preset.tolMb;
  $('#dur-min').value = preset.durMin;
  $('#dur-max').value = preset.durMax;
  $('#dur-eps').value = preset.durEps;
  $('#prefer-keep').checked = preset.preferKeep;
  $('#verbose').checked = preset.verbose;
  $('#show-ffmpeg').checked = preset.showFfmpeg;
};

const readParams = () => ({
  maxMb: Number($('#max-mb').value) || DEFAULT_PRESET.maxMb,
  maxW: Number($('#max-w').value) || DEFAULT_PRESET.maxW,
  tolMb: Number($('#tol-mb').value) || DEFAULT_PRESET.tolMb,
  durMin: Number($('#dur-min').value) || DEFAULT_PRESET.durMin,
  durMax: Number($('#dur-max').value) || DEFAULT_PRESET.durMax,
  durEps: Number($('#dur-eps').value) || DEFAULT_PRESET.durEps,
  preferKeep: $('#prefer-keep').checked,
  verbose: $('#verbose').checked,
  showFfmpeg: $('#show-ffmpeg').checked,
  saveOutputs: $('#save-outputs').checked,
});

const saveCurrentAsPreset = () => {
  const params = readParams();
  const name = prompt('为当前参数集命名：', `自定义 ${state.presets.length}`);
  if (!name) return;
  const newPreset = { ...params, id: crypto.randomUUID(), name };
  state.presets.push(newPreset);
  state.currentPresetId = newPreset.id;
  savePresets();
  renderPresets();
};

const toggleAdvanced = () => {
  const panel = $('#advanced-panel');
  const btn = $('#toggle-advanced');
  const hidden = panel.classList.toggle('hidden');
  btn.textContent = hidden ? '显示高级设置' : '收起高级设置';
};

const setGpuBadge = () => {
  const badge = $('#gpu-badge');
  if (navigator.gpu) {
    badge.textContent = 'GPU 可用 · WebGPU';
    badge.classList.add('ok');
  } else {
    badge.textContent = 'CPU 模式';
    badge.classList.add('warn');
  }
};

const ensureGifuct = async () => {
  if (!state.gifuct) {
    // use bundled local copy to avoid CORS/MIME issues from CDN
    state.gifuct = await import('./vendor/gifuct/gifuct.esm.js');
  }
  return state.gifuct;
};

const readMeta = async (file) => {
  const arrayBuffer = await file.arrayBuffer();
  return readMetaFromBuffer(arrayBuffer, file);
};

// 仅从已知 ArrayBuffer 读取元信息，不再保留原始 buffer（用于输出文件）
const readMetaFromBuffer = async (arrayBuffer, fileLike = null) => {
  let width = null;
  let height = null;
  let duration = null;
  let frameCount = null;
  try {
    const gifuct = await ensureGifuct();
    const gif = gifuct.parseGIF(arrayBuffer);
    const frames = gifuct.decompressFrames(gif, true);
    duration = frames.reduce((s, f) => s + (f.delay || 10), 0) / 1000;
    frameCount = frames.length;
    width = gif.lsd.width;
    height = gif.lsd.height;
  } catch (err) {
    console.warn('gif metadata parse failed', err);
  }

  if (!width || !height) {
    width = height = null;
    try {
      const blobUrl = URL.createObjectURL(new Blob([arrayBuffer], { type: 'image/gif' }));
      await new Promise((resolve) => {
        const img = new Image();
        img.onload = () => {
          width = img.naturalWidth;
          height = img.naturalHeight;
          URL.revokeObjectURL(blobUrl);
          resolve();
        };
        img.onerror = () => {
          URL.revokeObjectURL(blobUrl);
          resolve();
        };
        img.src = blobUrl;
      });
    } catch (_) {
      /* noop */
    }
  }

  return {
    rawBuffer: fileLike ? arrayBuffer : arrayBuffer, // 入参需要保留时用原值
    size: fileLike ? (fileLike.size ?? arrayBuffer.byteLength) : arrayBuffer.byteLength,
    width,
    height,
    duration,
    frameCount,
  };
};

const setTaskStatus = (taskEl, statusText, tone = 'muted') => {
  const row = taskEl.querySelector('.status-row');
  row.innerHTML = `<span class="badge ${tone}">${statusText}</span>`;
};

const upsertTaskCard = (task) => {
  let el = task.dom;
  if (!el) {
    const tpl = $('#task-item-tpl');
    el = tpl.content.cloneNode(true).firstElementChild;
    task.dom = el;
    $('#task-list').classList.remove('empty');
    const tip = document.querySelector('#task-list .empty-tip');
    if (tip) tip.style.display = 'none';
    $('#task-list').appendChild(el);
  }

  el.querySelector('.title').textContent = task.file.name;
  const outW = task.outputMeta?.width ?? task.meta.width ?? '?';
  const outH = task.outputMeta?.height ?? task.meta.height ?? '?';
  const outDur = task.outputMeta?.duration ?? task.meta.duration;
  const metricText = task.outputSize
    ? `原始 ${humanBytes(task.meta.size)} · ${task.meta.width || '?'}x${task.meta.height || '?'} · ${task.meta.duration ? `${task.meta.duration.toFixed(2)}s` : '时长未知'}\n输出 ${humanBytes(task.outputSize)} · ${outW}${outH ? `x${outH}` : ''} · 时长 ${outDur ? `${outDur.toFixed(2)}s` : '未知'} · 档位 ${task.bestIdx ?? '?'}`
    : `原始 ${humanBytes(task.meta.size)} · ${task.meta.width || '?'}x${task.meta.height || '?'} · ${task.meta.duration ? `${task.meta.duration.toFixed(2)}s` : '时长未知'}`;
  el.querySelector('.metrics').innerHTML = metricText.replace(/\\n/g, '<br>');
  if (task.thumbUrl) {
    el.querySelector('.thumb').style.backgroundImage = `url('${task.thumbUrl}')`;
  }

  el.querySelector('.download').onclick = () => {
    if (!task.outputBlob) return alert('还没有输出文件');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(task.outputBlob);
    a.download = task.file.name.replace(/\\.gif$/i, '_compressed.gif');
    a.click();
  };
  el.querySelector('.replay').onclick = () => {
    compressTask(task);
  };
  el.querySelector('.toggle-log').onclick = () => {
    const logEl = el.querySelector('.task-log');
    logEl.classList.toggle('hidden');
  };
  el.querySelector('.popup-log').onclick = () => {
    openLogModal(task.logs.join('\n') || '暂无日志', `任务日志 · ${task.file.name}`);
  };
  setTaskStatus(el, task.status || '排队中');
};

const addTaskLog = (taskId, line) => {
  const task = state.tasks.get(taskId);
  if (!task) return;
  task.logs.push(line);
  if (task.dom) {
    const logEl = task.dom.querySelector('.task-log');
    logEl.textContent = task.logs.join('\n');
  }
};

const compressTask = (task) => {
  const params = readParams();
  const inputBuffer = task.meta.rawBuffer.slice(0);
  const payload = {
    type: 'compress',
    id: task.id,
    buffer: inputBuffer,
    params,
    meta: {
      size: task.meta.size,
      width: task.meta.width,
      duration: task.meta.duration ?? null,
      durMin: params.durMin,
      durMax: params.durMax,
      durEps: params.durEps,
    },
  };
  setTaskStatus(task.dom, '压缩中…', 'muted');
  worker.postMessage(payload, [inputBuffer]);
};

const createTask = async (file) => {
  const meta = await readMeta(file);
  const id = crypto.randomUUID();
  const task = {
    id,
    file,
    meta,
    logs: [],
    outputBlob: null,
    thumbUrl: URL.createObjectURL(file),
  };
  state.tasks.set(id, task);
  upsertTaskCard(task);
  compressTask(task);
};

const handleFiles = async (files) => {
  for (const file of files) {
    if (!file.type.includes('gif')) continue;
    await createTask(file);
  }
};

const setupWorker = () => {
  worker.onmessage = async (event) => {
    const { type, id, payload } = event.data;
    if (type === 'ready') {
      state.workerReady = true;
      logGlobal('FFmpeg 已加载');
      return;
    }
    if (type === 'log') {
      if (id) addTaskLog(id, payload);
      else logGlobal(payload);
      return;
    }
    if (type === 'done') {
      const task = state.tasks.get(id);
      if (!task) return;
      const outBuf = new Uint8Array(payload.buffer);
      task.outputBlob = new Blob([outBuf], { type: 'image/gif' });
      // 读取输出元信息以更新宽度/时长显示
      try {
        task.outputMeta = await readMetaFromBuffer(outBuf.buffer);
      } catch (e) {
        console.warn('读取输出元信息失败', e);
      }
      task.status = payload.hit ? '达标' : '接近目标';
      task.outputSize = outBuf.length;
      task.bestIdx = payload.bestIdx;
      addTaskLog(id, `完成，体积 ${humanBytes(outBuf.length)}，命中容差=${payload.hit}, 档位=${payload.bestIdx}`);
      upsertTaskCard(task);
      setTaskStatus(task.dom, task.status, payload.hit ? 'ok' : 'warn');
      if (!task.thumbUrl) {
        task.thumbUrl = URL.createObjectURL(task.outputBlob);
      }
      return;
    }
    if (type === 'error') {
      const task = state.tasks.get(id);
      if (task) {
        addTaskLog(id, `错误：${payload}`);
        setTaskStatus(task.dom, '出错', 'err');
      } else {
        logGlobal(`错误：${payload}`);
      }
    }
  };
  worker.postMessage({ type: 'init' });
};

const bindUI = () => {
  $('#primary-action').onclick = () => $('#file-input').click();
  $('#file-input').onchange = (e) => handleFiles(e.target.files);
  $('#add-preset').onclick = saveCurrentAsPreset;
  $('#toggle-advanced').onclick = toggleAdvanced;
  $('#clear-logs').onclick = () => { $('#log-output').textContent = ''; };
  $('#popup-logs').onclick = () => openLogModal($('#log-output').textContent || '暂无日志', '全局日志');

  const dz = $('#dropzone');
  const prevent = (e) => { e.preventDefault(); e.stopPropagation(); };
  ['dragenter', 'dragover', 'dragleave', 'drop'].forEach((ev) => dz.addEventListener(ev, prevent));
  dz.addEventListener('drop', (e) => {
    handleFiles(e.dataTransfer.files);
  });
};

const bootstrap = () => {
  loadPresets();
  applyPreset(state.presets.find((p) => p.id === state.currentPresetId) || DEFAULT_PRESET);
  renderPresets();
  bindUI();
  setupWorker();
  setGpuBadge();
  setupLogModal();
};

document.addEventListener('DOMContentLoaded', bootstrap);

// ---------- 日志弹窗 ----------
let logModal = null;
let logModalBody = null;
let logModalTitle = null;
const setupLogModal = () => {
  logModal = $('#log-modal');
  logModalBody = $('#log-modal-body');
  logModalTitle = $('#log-modal-title');
  $('#log-modal-close').onclick = () => closeLogModal();
  logModal.addEventListener('click', (e) => {
    if (e.target === logModal) closeLogModal();
  });
};

const openLogModal = (text, title = '日志') => {
  if (!logModal) return;
  logModalBody.textContent = text;
  logModalTitle.textContent = title;
  logModal.classList.add('active');
};

const closeLogModal = () => {
  if (!logModal) return;
  logModal.classList.remove('active');
};
