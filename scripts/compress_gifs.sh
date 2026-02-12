#!/usr/bin/env bash
set -euo pipefail

# 用法:
#   ./compress_gifs.sh /path/to/in_dir /path/to/out_dir
#
# 可选环境变量:
#   MAX_MB=9             (目标上限，默认 9MB)
#   MAX_W=1024           (最大宽度，默认 1024；即使体积已达标，也会确保输出宽度不超过此值)
#   TOL_MB=1             (允许误差范围，默认 1MB)
#   DUR_MIN=0            (目标时长下限秒，默认 0)
#   DUR_MAX=4            (目标时长上限秒，默认 4)
#   DUR_EPS=0.02         (时长比较容差秒，默认 0.02；避免 ffprobe 浮点误差导致误判)
#   VERBOSE_TRIALS=0     (设为 1 打印每个档位结果)
#   SHOW_FFMPEG=0        (设为 1 显示 ffmpeg 输出)

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
DUR_MIN="${DUR_MIN:-0}"
DUR_MAX="${DUR_MAX:-4}"
DUR_EPS="${DUR_EPS:-0.02}"
VERBOSE_TRIALS="${VERBOSE_TRIALS:-0}"
SHOW_FFMPEG="${SHOW_FFMPEG:-0}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 2; }; }
need_cmd ffmpeg
need_cmd ffprobe
need_cmd find
need_cmd realpath
need_cmd stat
need_cmd mktemp
need_cmd awk

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

gif_width() {
  # 输出数字宽度；失败则输出空
  ffprobe -v error -select_streams v:0 -show_entries stream=width \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 | tr -d '\r'
}

gif_duration() {
  # 输出秒数(浮点)，失败则输出空
  local d=""
  d="$(ffprobe -v error -show_entries format=duration \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 | tr -d '\r')"

  if [[ -n "$d" && "$d" != "N/A" ]]; then
    echo "$d"
    return 0
  fi

  # fallback: 累加每帧 pkt_duration_time
  d="$(ffprobe -v error -select_streams v:0 -show_entries frame=pkt_duration_time \
    -of csv=p=0 "$1" 2>/dev/null \
    | awk 'BEGIN{sum=0} {if($1!="") sum+=$1} END{if(sum>0) printf "%.6f", sum}')"
  if [[ -n "$d" ]]; then
    echo "$d"
    return 0
  fi

  # fallback2: stream duration
  d="$(ffprobe -v error -select_streams v:0 -show_entries stream=duration \
    -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 | tr -d '\r')"
  if [[ -n "$d" && "$d" != "N/A" ]]; then
    echo "$d"
    return 0
  fi

  return 1
}

log() { echo "[$(ts)] $*"; }

check_duration_range() {
  # return:
  #   0 ok
  #   1 out of range
  #   2 unknown
  local f="$1"
  local d
  d="$(gif_duration "$f" || true)"
  if [[ -z "$d" ]]; then
    return 2
  fi
  if awk -v d="$d" -v lo="$DUR_MIN" -v hi="$DUR_MAX" -v eps="$DUR_EPS" 'BEGIN{
    exit !((d+0) >= (lo-eps) && (d+0) <= (hi+eps))
  }'; then
    return 0
  fi
  return 1
}

# 全局档位数组：越往后压得越狠、体积越小（大致单调）
# 第二维 fps 可以是数字，或 "keep" 表示不强制重采样 fps（尽量保留原时间轴/帧间隔）
build_profiles() {
  local prefer_keep_timing="${1:-0}"

  profiles=()

  if [[ "$prefer_keep_timing" == "1" ]]; then
    # 先尝试只缩放/尽量保留 fps 的组合（常见于“只需要调宽度/时长、不想动帧采样”的场景）
    profiles+=(
      "$max_w keep 256"
      "$max_w keep 192"
      "$max_w keep 160"
    )
  fi

  # 常规压缩档位（含降 fps）
  profiles+=(
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
# timefix_prefix
# profiles[], best_file, best_size, best_diff, best_side, best_idx
# hit_within_tol, last_sz, last_side

try_profile() {
  local idx="$1"
  local w fps colors
  read -r w fps colors <<< "${profiles[idx]}"

  log "  PROFILE idx=$idx: w=$w fps=$fps colors=$colors"

  local palette="$tmpdir/palette_${idx}.png"
  local trial="$tmpdir/trial_${idx}.gif"

  local fps_prefix=""
  if [[ "$fps" != "keep" ]]; then
    fps_prefix="fps=${fps},"
  fi

  if ! ffmpeg -y $ffv -i "$in" \
    -vf "${timefix_prefix}${fps_prefix}scale='min(iw,${w})':-1:flags=lanczos,palettegen=max_colors=${colors}:stats_mode=diff:reserve_transparent=1" \
    "$palette"; then
    log "    palettegen FAIL, skip"
    return 1
  fi

  if ! ffmpeg -y $ffv -i "$in" -i "$palette" \
    -filter_complex "[0:v]${timefix_prefix}${fps_prefix}scale='min(iw,${w})':-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    -loop 0 "$trial"; then
    log "    encode FAIL, skip"
    return 1
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

  local in_sz in_w
  in_sz="$(file_size "$in")"
  in_w="$(gif_width "$in" || true)"

  log "START file"
  log "  IN : $in"
  log "  OUT: $out"
  log "  IN_SIZE : $in_sz ($(human_bytes "$in_sz"))"
  log "  LIMIT   : $max_bytes ($(human_bytes "$max_bytes"))"
  log "  MAX_W   : $max_w"

  if [[ -n "$in_w" ]]; then
    log "  IN_W    : $in_w"
  else
    log "  IN_W    : (unknown; ffprobe failed) -> will enforce scaling by re-encode"
    in_w=$((max_w + 1))
  fi

  log "  TOL     : $tol_bytes ($(human_bytes "$tol_bytes"))"
  log "  DUR_RANGE: ${DUR_MIN}-${DUR_MAX}s (eps=${DUR_EPS}s)"

  # 最优先：时长归一化（若不在范围内则通过 setpts 加速/减速；帧数不变，等效 fps 会随之变化）
  local in_dur
  in_dur="$(gif_duration "$in" || true)"

  if [[ -n "$in_dur" ]]; then
    log "  IN_DUR  : ${in_dur}s"
  else
    log "  IN_DUR  : (unknown; ffprobe failed)"
  fi

  local need_dur=0
  timefix_prefix=""

  if [[ -n "$in_dur" ]]; then
    need_dur="$(awk -v d="$in_dur" -v lo="$DUR_MIN" -v hi="$DUR_MAX" -v eps="$DUR_EPS" 'BEGIN{
      if ((d+0) < (lo-eps) || (d+0) > (hi+eps)) print 1; else print 0
    }')"

    if (( need_dur == 1 )); then
      local target_dur speed_factor
      target_dur="$(awk -v d="$in_dur" -v lo="$DUR_MIN" -v hi="$DUR_MAX" 'BEGIN{
        t=d+0; if(t<lo) t=lo; if(t>hi) t=hi;
        if(t<=0) t=0.001;
        printf "%.6f", t
      }')"

      speed_factor="$(awk -v old="$in_dur" -v new="$target_dur" 'BEGIN{
        if(old<=0){exit 1}
        printf "%.10f", (new/old)
      }' || true)"

      if [[ -n "$speed_factor" ]]; then
        timefix_prefix="setpts=${speed_factor}*PTS,"
        if awk -v f="$speed_factor" 'BEGIN{exit !(f<1)}'; then
          log "  NEED_DUR: 1 (speed up)  target=${target_dur}s factor=${speed_factor}"
        elif awk -v f="$speed_factor" 'BEGIN{exit !(f>1)}'; then
          log "  NEED_DUR: 1 (slow down) target=${target_dur}s factor=${speed_factor}"
        else
          log "  NEED_DUR: 1 (no-op?)   target=${target_dur}s factor=${speed_factor}"
        fi
      else
        log "  NEED_DUR: 1 but cannot compute factor -> skip duration normalization"
        need_dur=0
        timefix_prefix=""
      fi
    else
      log "  NEED_DUR: 0"
    fi
  else
    log "  NEED_DUR: (unknown) -> skip duration normalization"
  fi

  local need_size=0
  local need_scale=0
  if (( in_sz > max_bytes )); then need_size=1; fi
  if (( in_w > max_w )); then need_scale=1; fi

  log "  NEED_SIZE : $need_size"
  log "  NEED_SCALE: $need_scale"
  log "  NEED_DUR  : $need_dur"

  # 只有在：体积达标 且 宽度达标 且 时长达标 时，才直接复制
  if (( need_size == 0 && need_scale == 0 && need_dur == 0 )); then
    cp -f "$in" "$out"
    log "  SKIP COMPRESS: already <= limit AND width ok AND duration ok, copied as is"
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

  # 若“只需要缩放/只需要调时长”（体积已达标），优先尝试 keep fps 的档位
  local prefer_keep_timing=0
  if (( (need_scale == 1 && need_size == 0) || (need_dur == 1 && need_size == 0) )); then
    prefer_keep_timing=1
  fi

  build_profiles "$prefer_keep_timing"
  local total_profiles="${#profiles[@]}"
  log "  PROFILE_COUNT: $total_profiles (prefer_keep_timing=$prefer_keep_timing)"

  if (( total_profiles == 0 )); then
    log "  ERROR: no profiles defined, copy original"
    cp -f "$in" "$out"
    log "END  file WARN (no profiles)"
    return 1
  fi

  # 先试边界：最轻和最重（注意 set -e，失败要吞掉）
  try_profile 0 || true
  if (( hit_within_tol == 1 )); then
    if [[ -f "$best_file" ]]; then
      cp -f "$best_file" "$out"
      check_duration_range "$out"
      case "$?" in
        0) log "  OUT_DUR : $(gif_duration "$out" || true)s (OK)" ;;
        1) log "  OUT_DUR : $(gif_duration "$out" || true)s (OUT OF RANGE!)" ; log "END  file WARN (duration out of range)"; return 1 ;;
        2) log "  OUT_DUR : (unknown; ffprobe failed)" ;;
      esac
      log "END  file OK (hit at idx=0 boundary)"
      return 0
    else
      log "  ERROR: best_file missing after trials, copy original"
      cp -f "$in" "$out"
      log "END  file WARN (encode failed)"
      return 1
    fi
  fi

  if (( total_profiles > 1 )); then
    local last_idx=$((total_profiles - 1))
    try_profile "$last_idx" || true
    if (( hit_within_tol == 1 )); then
      if [[ -f "$best_file" ]]; then
        cp -f "$best_file" "$out"
        check_duration_range "$out"
        case "$?" in
          0) log "  OUT_DUR : $(gif_duration "$out" || true)s (OK)" ;;
          1) log "  OUT_DUR : $(gif_duration "$out" || true)s (OUT OF RANGE!)" ; log "END  file WARN (duration out of range)"; return 1 ;;
          2) log "  OUT_DUR : (unknown; ffprobe failed)" ;;
        esac
        log "END  file OK (hit at idx=$last_idx boundary)"
        return 0
      else
        log "  ERROR: best_file missing after trials, copy original"
        cp -f "$in" "$out"
        log "END  file WARN (encode failed)"
        return 1
      fi
    fi
  fi

  # 如果只有 1 或 2 个档位，边界已经试完，直接用 best
  if (( total_profiles <= 2 )); then
    if [[ -f "$best_file" ]]; then
      cp -f "$best_file" "$out"
      check_duration_range "$out"
      case "$?" in
        0) log "  OUT_DUR : $(gif_duration "$out" || true)s (OK)" ;;
        1) log "  OUT_DUR : $(gif_duration "$out" || true)s (OUT OF RANGE!)" ; log "END  file WARN (duration out of range)"; return 1 ;;
        2) log "  OUT_DUR : (unknown; ffprobe failed)" ;;
      esac
      if (( hit_within_tol == 1 )); then
        log "END  file OK (small profile set)"
        return 0
      else
        log "END  file WARN (no profile within tolerance, used best boundary idx=$best_idx)"
        return 1
      fi
    else
      log "  ERROR: best_file missing after trials, copy original"
      cp -f "$in" "$out"
      log "END  file WARN (encode failed)"
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

    try_profile "$mid" || true

    if (( hit_within_tol == 1 )); then
      break
    fi

    # 太大 -> 往更重压缩（右边，idx 变大）
    # 不大于目标 -> 往更轻压缩（左边，idx 变小）
    if (( last_sz > target )); then
      l=$((mid + 1))
    else
      r=$((mid - 1))
    fi
  done

  if [[ -f "$best_file" ]]; then
    cp -f "$best_file" "$out"
    check_duration_range "$out"
    case "$?" in
      0) log "  OUT_DUR : $(gif_duration "$out" || true)s (OK)" ;;
      1) log "  OUT_DUR : $(gif_duration "$out" || true)s (OUT OF RANGE!)" ; log "END  file WARN (duration out of range)"; return 1 ;;
      2) log "  OUT_DUR : (unknown; ffprobe failed)" ;;
    esac

    if (( hit_within_tol == 1 )); then
      log "END  file OK (hit within tolerance, best_idx=$best_idx size=$best_size ($(human_bytes "$best_size")))"
      return 0
    else
      log "END  file WARN (no profile within tolerance, used best_idx=$best_idx size=$best_size ($(human_bytes "$best_size")))"
      return 1
    fi
  else
    log "  ERROR: best_file missing after trials, copy original"
    cp -f "$in" "$out"
    log "END  file WARN (encode failed)"
    return 1
  fi
}

in_dir_abs="$(realpath "$in_dir")"
out_dir_abs="$(realpath "$out_dir")"

log "JOB START"
log "  INPUT_DIR : $in_dir_abs"
log "  OUTPUT_DIR: $out_dir_abs"
log "  LIMIT     : $max_bytes ($(human_bytes "$max_bytes"))"
log "  MAX_W     : $max_w"
log "  TOL       : $tol_bytes ($(human_bytes "$tol_bytes"))"
log "  DUR_RANGE : ${DUR_MIN}-${DUR_MAX}s (eps=${DUR_EPS}s)"

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
