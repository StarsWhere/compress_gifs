#!/usr/bin/env bash
set -euo pipefail

# 用法:
#   ./compress_gifs.sh /path/to/in_dir /path/to/out_dir
#
# 可选环境变量:
#   MAX_MB=10            (目标上限，默认 10MB)
#   MAX_W=1024           (最大宽度，默认 1024)
#   TOL_MB=1             (允许误差范围，默认 1MB)
#   VERBOSE_TRIALS=0     (设为 1 打印每个档位结果)
#   SHOW_FFMPEG=0        (设为 1 显示 ffmpeg 输出)
#   HWACCEL=auto         (ffmpeg 硬件加速模式，auto/off/cuda/vaapi...)

in_dir="${1:-}"
out_dir="${2:-}"

if [[ -z "${in_dir}" || -z "${out_dir}" ]]; then
  echo "Usage: $0 <input_dir> <output_dir>"
  exit 2
fi
if [[ ! -d "$in_dir" ]]; then
  echo "Error: input_dir not found: $in_dir"
  exit 2
fi
mkdir -p "$out_dir"

MAX_MB="${MAX_MB:-9}"
max_bytes=$((MAX_MB * 1024 * 1024))
max_w="${MAX_W:-1024}"
TOL_MB="${TOL_MB:-1}"
tol_bytes=$((TOL_MB * 1024 * 1024))
VERBOSE_TRIALS="${VERBOSE_TRIALS:-0}"
SHOW_FFMPEG="${SHOW_FFMPEG:-0}"
HWACCEL="${HWACCEL:-auto}"
hw_enabled=1

case "${HWACCEL,,}" in
  ""|"0"|"off"|"false"|"cpu"|"none")
    hw_enabled=0
    HWACCEL="off"
    ;;
  *)
    : # keep hw_enabled=1
    ;;
esac

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 2; }; }
need_cmd ffmpeg
need_cmd find
need_cmd realpath
need_cmd stat
need_cmd mktemp

ts() { date +"%Y-%m-%d %H:%M:%S"; }

human_bytes() {
  local b="$1"
  if (( b < 1024 )); then echo "${b}B"; return; fi
  if (( b < 1024*1024 )); then awk -v b="$b" 'BEGIN{printf "%.2fKB", b/1024}'; return; fi
  awk -v b="$b" 'BEGIN{printf "%.2fMB", b/1024/1024}'
}

file_size() {
  stat -c '%s' "$1" 2>/dev/null || wc -c < "$1"
}

log() { echo "[$(ts)] $*"; }

# 全局档位数组：越往后压得越狠、体积越小（大致单调）
build_profiles() {
  profiles=(
    "$max_w 18 256"
    "$max_w 15 256"
    "$max_w 12 192"
    "960 12 192"
    "832 10 160"
    "768 10 128"
    "640 8 128"
    "576 8 96"
    "512 8 96"
    "448 6 80"
    "384 5 64"
    "320 4 64"
    "256 4 48"
    "256 4 32"
  )
}

# 下面几个变量在 process_one 和 try_profile 之间共享:
# in, target, tol_bytes, tmpdir, ffv
# profiles[], best_file, best_size, best_diff, best_side, best_idx
# hit_within_tol, last_sz, last_side

try_profile() {
  local idx="$1"
  local w fps colors
  read -r w fps colors <<< "${profiles[idx]}"

  log "  PROFILE idx=$idx: w=$w fps=$fps colors=$colors"

  local palette="$tmpdir/palette_${idx}.png"
  local trial="$tmpdir/trial_${idx}.gif"

  local palette_vf="fps=${fps},scale='min(iw,${w})':-1:flags=lanczos,palettegen=max_colors=${colors}:stats_mode=diff:reserve_transparent=1"
  local encode_fc="fps=${fps},scale='min(iw,${w})':-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"

  local palette_cmd=(ffmpeg -y)
  [[ -n "$ffv" ]] && palette_cmd+=($ffv)
  if (( hw_enabled )); then
    palette_cmd+=(-hwaccel "$HWACCEL")
  fi
  palette_cmd+=(-i "$in" -vf "$palette_vf" "$palette")

  if ! "${palette_cmd[@]}"; then
    if (( hw_enabled )); then
      log "    HW accel failed for palettegen, fallback to CPU"
      hw_enabled=0
      palette_cmd=(ffmpeg -y)
      [[ -n "$ffv" ]] && palette_cmd+=($ffv)
      palette_cmd+=(-i "$in" -vf "$palette_vf" "$palette")
      if ! "${palette_cmd[@]}"; then
        log "    palettegen FAIL, skip"
        return 1
      fi
    else
      log "    palettegen FAIL, skip"
      return 1
    fi
  fi

  local encode_cmd=(ffmpeg -y)
  [[ -n "$ffv" ]] && encode_cmd+=($ffv)
  if (( hw_enabled )); then
    encode_cmd+=(-hwaccel "$HWACCEL")
  fi
  encode_cmd+=(-i "$in" -i "$palette" -filter_complex "$encode_fc" -loop 0 "$trial")

  if ! "${encode_cmd[@]}"; then
    if (( hw_enabled )); then
      log "    HW accel failed for encode, fallback to CPU"
      hw_enabled=0
      encode_cmd=(ffmpeg -y)
      [[ -n "$ffv" ]] && encode_cmd+=($ffv)
      encode_cmd+=(-i "$in" -i "$palette" -filter_complex "$encode_fc" -loop 0 "$trial")
      if ! "${encode_cmd[@]}"; then
        log "    encode FAIL, skip"
        return 1
      fi
    else
      log "    encode FAIL, skip"
      return 1
    fi
  fi

  local sz
  sz="$(file_size "$trial")"
  last_sz="$sz"

  local abs_diff side
  if (( sz > target )); then
    abs_diff=$((sz - target))
    side=1        # 大于目标
  else
    abs_diff=$((target - sz))
    side=-1       # 小于等于目标
  fi
  last_side="$side"

  if [[ "$VERBOSE_TRIALS" == "1" ]]; then
    log "    RESULT size=$sz ($(human_bytes "$sz")) diff=$abs_diff side=$side"
  fi

  # 更新“最接近目标”的候选：
  # 1. diff 更小
  # 2. diff 相等时，优先选择 <= 目标（side=-1）而不是 > 目标（side=1）
  if (( best_size == 0 || abs_diff < best_diff || (abs_diff == best_diff && side <= 0 && best_side > 0) )); then
    cp -f "$trial" "$best_file"
    best_size="$sz"
    best_diff="$abs_diff"
    best_side="$side"
    best_idx="$idx"
    log "    BEST_UPDATE -> size=$best_size ($(human_bytes "$best_size")) diff=$best_diff side=$best_side (idx=$best_idx)"
  fi

  # 命中“可接受范围”：要求在目标以下（或等于）并且误差 <= tol
  if (( side <= 0 && abs_diff <= tol_bytes )); then
    hit_within_tol=1
    log "    HIT within tolerance (<=limit): size=$sz ($(human_bytes "$sz")) diff=$abs_diff"
  fi

  return 0
}

process_one() {
  # 这里用全局变量 in/out，方便 try_profile 访问
  in="$1"
  out="$2"

  mkdir -p "$(dirname "$out")"

  local in_sz
  in_sz="$(file_size "$in")"
  log "START file"
  log "  IN : $in"
  log "  OUT: $out"
  log "  IN_SIZE : $in_sz ($(human_bytes "$in_sz"))"
  log "  LIMIT   : $max_bytes ($(human_bytes "$max_bytes"))"
  log "  TOL     : $tol_bytes ($(human_bytes "$tol_bytes"))"

  # 如果原文件已经 <= 上限，直接复制（避免无意义重编码）
  if (( in_sz <= max_bytes )); then
    cp -f "$in" "$out"
    log "  SKIP COMPRESS: already <= limit, copied as is"
    log "END  file OK (no re-encode)"
    return 0
  fi

  if [[ -f "$out" ]]; then
    local out_sz
    out_sz="$(file_size "$out")"
    log "  OUT_EXISTS: yes, size=$out_sz ($(human_bytes "$out_sz"))"
  else
    log "  OUT_EXISTS: no"
  fi

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  best_file="$tmpdir/best.gif"
  best_size=0
  best_diff=0
  best_side=0
  best_idx=-1
  hit_within_tol=0
  last_sz=0
  last_side=0

  target="$max_bytes"

  ffv="-v error"
  if [[ "$SHOW_FFMPEG" == "1" ]]; then
    ffv=""
  fi

  build_profiles
  local total_profiles="${#profiles[@]}"
  log "  PROFILE_COUNT: $total_profiles"

  if (( total_profiles == 0 )); then
    log "  ERROR: no profiles defined, copy original"
    cp -f "$in" "$out"
    log "END  file WARN (no profiles)"
    return 1
  fi

  # 先试边界：最轻和最重
  try_profile 0
  if (( hit_within_tol == 1 )); then
    cp -f "$best_file" "$out"
    log "END  file OK (hit at idx=0 boundary)"
    return 0
  fi

  if (( total_profiles > 1 )); then
    local last_idx=$((total_profiles - 1))
    try_profile "$last_idx"
    if (( hit_within_tol == 1 )); then
      cp -f "$best_file" "$out"
      log "END  file OK (hit at idx=$last_idx boundary)"
      return 0
    fi
  fi

  # 如果只有 1 或 2 个档位，边界已经试完，直接用 best
  if (( total_profiles <= 2 )); then
    cp -f "$best_file" "$out"
    if (( hit_within_tol == 1 )); then
      log "END  file OK (small profile set)"
      return 0
    else
      log "END  file WARN (no profile within tolerance, used best boundary idx=$best_idx)"
      return 1
    fi
  fi

  # 对中间档位用“二分”逻辑：每轮只试一个 mid 档
  local l=1
  local r=$((total_profiles - 2))
  local iterations=0
  local max_iterations=$((total_profiles * 2))

  while (( l <= r && iterations < max_iterations && hit_within_tol == 0 )); do
    ((iterations++)) || true
    local mid=$(((l + r) / 2))
    log "  BSEARCH iter=$iterations l=$l r=$r mid=$mid"

    try_profile "$mid"

    # 如果已经命中“误差范围内且 <= 限制”，直接停
    if (( hit_within_tol == 1 )); then
      break
    fi

    # 根据当前结果大小决定往哪边搜：
    # 太大 -> 往更重压缩（右边，idx 变大）
    # 不大于目标 -> 往更轻压缩（左边，idx 变小），试图找更清晰但仍接近目标
    if (( last_sz > target )); then
      l=$((mid + 1))
    else
      r=$((mid - 1))
    fi
  done

  cp -f "$best_file" "$out"
  if (( hit_within_tol == 1 )); then
    log "END  file OK (hit within tolerance, best_idx=$best_idx size=$best_size ($(human_bytes "$best_size")))"

    return 0
  else
    log "END  file WARN (no profile within tolerance, used best_idx=$best_idx size=$best_size ($(human_bytes "$best_size")))"

    # 这里返回 1 表示“未达误差要求”，但写出了“最贴合”的结果
    return 1
  fi
}

in_dir_abs="$(realpath "$in_dir")"
out_dir_abs="$(realpath "$out_dir")"

log "JOB START"
log "  INPUT_DIR : $in_dir_abs"
log "  OUTPUT_DIR: $out_dir_abs"
log "  LIMIT     : $max_bytes ($(human_bytes "$max_bytes"))"
log "  TOL       : $tol_bytes ($(human_bytes "$tol_bytes"))"
log "  HWACCEL   : $HWACCEL (enabled=${hw_enabled})"

mapfile -d '' files < <(find "$in_dir_abs" -type f -iname '*.gif' -print0)

total="${#files[@]}"
log "FOUND $total gif(s)"

overall_rc=0
ok_cnt=0
warn_cnt=0
idx=0

for f in "${files[@]}"; do
  ((idx++)) || true
  rel="${f#$in_dir_abs/}"
  out_path="$out_dir_abs/$rel"

  log "========================================"
  log "FILE $idx/$total: $rel"

  if process_one "$f" "$out_path"; then
    ((ok_cnt++)) || true
  else
    ((warn_cnt++)) || true
    overall_rc=1
  fi
done

log "========================================"
log "JOB END"
log "  TOTAL=$total OK=$ok_cnt WARN=$warn_cnt"
log "  OUTPUT_DIR: $out_dir_abs"
exit "$overall_rc"
