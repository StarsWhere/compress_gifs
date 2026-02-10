# GIF 批量压缩脚本（compress_gifs.sh）

该脚本会递归扫描输入目录内的所有 `.gif` 文件，使用 ffmpeg 多档位压缩策略，将输出控制在指定大小上限附近，并保持与输入目录一致的相对路径结构输出到目标目录。

## 依赖

- Bash
- ffmpeg
- 常用工具：`find`, `realpath`, `stat`, `mktemp`

> 在 Windows 上建议使用 WSL 或 Git Bash 运行。

## 用法

```bash
./compress_gifs.sh <input_dir> <output_dir>
```

示例：

```bash
./compress_gifs.sh ./gifs_in ./gifs_out
```

## 可选环境变量

- `MAX_MB`：目标体积上限（默认 **9MB**）
- `MAX_W`：最大宽度（默认 **1024**，按原图等比缩放）
- `TOL_MB`：允许误差范围（默认 **1MB**）
- `VERBOSE_TRIALS`：设为 `1` 时打印每个档位的结果（默认 `0`）
- `SHOW_FFMPEG`：设为 `1` 时显示 ffmpeg 的输出（默认 `0`）

示例：

```bash
MAX_MB=8 TOL_MB=1 MAX_W=960 ./compress_gifs.sh ./gifs_in ./gifs_out
```

## 行为说明

- 递归查找输入目录下所有 `.gif`（大小写不敏感）。
- 输出目录会自动创建，且保持相同的目录结构。
- 若原文件大小已经小于等于 `MAX_MB`，会直接复制，不做重新编码。
- 如果没有档位能落在误差范围内，脚本仍会输出“最接近目标”的结果，并将该文件标记为 WARN。

## 退出码

- `0`：所有文件都在允许范围内完成压缩。
- `1`：有文件未落在容差范围内，但仍输出了最接近的结果。
- `2`：用法错误或缺少依赖命令。

## 提示

- 若图片尺寸较大且压缩困难，可适当调低 `MAX_W` 或 `MAX_MB`。
- 脚本内部使用多档位策略（帧率、颜色数、宽度组合）和二分搜索，尽量在清晰度与体积间折中。
