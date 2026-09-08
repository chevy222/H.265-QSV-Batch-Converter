# H.265 QSV Batch Converter

基于 **Intel Quick Sync（QSV）硬解硬编**的 Windows 批量转码脚本：把当前目录下所有 `*.mp4` 一键转为 H.265/HEVC，支持 90° 旋转、分辨率封顶、码率自适应和音频自动增益，解码→处理→编码全程帧不下显卡。

典型场景：手机录像方向纠正、老视频统一压成 H.265 省空间、音量偏小的录像自动拉满到不削顶。

---

## 功能特性

- **全硬件流水线**：`-hwaccel qsv` 解码 → `vpp_qsv`/`scale_qsv` 旋转缩放 → `hevc_qsv` 编码，帧始终留在 GPU，不回读内存
- **批量处理**：自动遍历**当前目录**下所有 `*.mp4`，逐个转码并汇总 `OK / FAIL / SKIP`
- **三种旋转模式**：顺时针 90°（默认）/ 逆时针 90° / 不旋转，支持交互提问或命令行参数
- **码率自适应**：沿用源视频码率、5000 kbps 封顶，并设置 `maxrate = 1.2×`、`bufsize = 2×`
- **分辨率封顶**：限制在 1920×1080 以内，保持宽高比、**不放大**、自动对齐为偶数尺寸
- **音频自动增益**：先扫描音量峰值，放大到恰好不削顶（0 dBFS）；若本就接近满度则直接流复制、不重编码
- **容错与续跑**：输出到桌面、同名文件自动跳过（不覆盖）；转码失败自动删除残缺文件
- **ffmpeg 双路径查找**：优先脚本内置路径，找不到自动回退到 PATH 环境变量

## 环境要求

| 项    | 要求                                                            |
| ---- | ------------------------------------------------------------- |
| 操作系统 | Windows（`.bat` / cmd 脚本，不依赖 PowerShell）                       |
| 硬件   | 支持 Intel Quick Sync 的核显（需支持 HEVC 编码，Skylake 及以后的多数 iGPU），驱动正常 |
| 软件   | ffmpeg、ffprobe（需包含 `hevc_qsv`，官方 full/essentials build 均可）    |

> NVIDIA / AMD 独显无法直接使用本脚本（编码写死为 QSV），需自行替换为 `hevc_nvenc` / `hevc_amf`。

## 安装 ffmpeg

脚本按以下顺序查找 ffmpeg / ffprobe，**任一满足即可**：

1. **内置路径**：`D:\software\ffmpeg\bin\ffmpeg.exe`（可修改脚本顶部变量 `FF` / `FP` 指向你自己的安装位置）；

2. **PATH 环境变量**：内置路径不存在时，自动用 `where` 查找 PATH 上的 `ffmpeg` / `ffprobe`。例如用 winget 安装：
   
   ```bat
   winget install Gyan.FFmpeg
   ```

两者都找不到时会打印 `[ERROR]` 并退出，不会继续空跑。

## 使用方法

把 `convert_h265.bat` 放进视频所在目录，双击运行，或在该目录打开 cmd：

```bat
:: 直接运行，按提示输入旋转方式（直接回车 = 顺时针 90°）
convert_h265.bat

:: 用参数跳过提问：
convert_h265.bat 1   REM 1 = 逆时针 90°
convert_h265.bat 2   REM 2 = 不旋转（仅缩放/转码）
```

运行后会先打印本次配置，例如：

```text
Source : D:\videos\
FFmpeg : D:/software/ffmpeg/bin/ffmpeg.exe
Output : C:\Users\you\Desktop
Rotate : clockwise 90
Audio  : auto max no-clip gain
----------------------------------------
[CONV] "VID_0001.mp4" : bitrate 4200k (peak 5040k), rotate clockwise 90, audio +6.3dB @ 128k
[OK] "VID_0001.mp4"
----------------------------------------
All done. OK=1  FAIL=0  SKIP=0
```

**输出位置**：`%USERPROFILE%\Desktop`（桌面），与源文件同名；桌面上已存在同名文件时直接 `[SKIP]`，可安全重复运行。

## 转码策略说明

| 维度   | 策略                                                                   |
| ---- | -------------------------------------------------------------------- |
| 视频编码 | H.265/HEVC（`hevc_qsv`），`-low_power 1 -preset veryfast -extbrc 1`     |
| 视频码率 | 依次探测：视频流码率 → 容器总码率 → 兜底 3500k；最终封顶 5000k；`maxrate=1.2×`、`bufsize=2×` |
| 分辨率  | 不超过 1920×1080，保持比例、不放大、宽高取偶数                                         |
| 旋转   | `vpp_qsv transpose` 在 GPU 上完成；默认顺时针 90°，可选逆时针或不转                     |
| 帧率   | 保持源帧率，不重采样                                                           |
| 音频增益 | `volumedetect` 扫描峰值 → 计算最大无削顶增益 → `volume` 滤镜放大到 0 dBFS              |
| 音频编码 | 需要增益时转 AAC，码率取源音频码率并钳制在 64–192k（探测不到则 128k）；无需增益时 `-c:a copy` 直接复制   |
| 封装   | MP4 + `+faststart`（moov 前置，便于网页/手机拖动播放）                              |

## 处理流程（每个文件）

1. 桌面已有同名输出 → 跳过；
2. ffprobe 探测视频码率（三级回退）并计算目标码率、峰值码率与缓冲区；
3. ffmpeg `volumedetect` 扫描音频峰值，计算增益量与音频码率；
4. 全 QSV 流水线一次完成旋转/缩放 + H.265 编码 + 音频处理；
5. 校验退出码：失败则删除残缺输出并计入 FAIL，成功计入 OK。

## 已知限制与踩坑记录

- **源编码限制**：QSV 硬解仅保证 H.264 / HEVC 输入；MPEG-4 等编码可能出现 `frame=0` 却返回退出码 0 的**静默假成功**（没有输出文件却看似成功），使用前请确认源是 H.264/HEVC。
- **刻意不启用 `-look_ahead_depth`**：在部分 QSV 驱动上会触发 `Invalid FrameType:0`（退出码 183），故脚本中省略该参数。
- **仅处理当前目录一层**的 `*.mp4`：不递归子目录，也不匹配 `.mov`/`.mkv` 等其他容器（可自行修改 `for` 行的通配符）。
- 输出目录固定为桌面，可修改脚本顶部 `OUTDIR` 变量。
- 每个文件需要先跑一遍音频峰值扫描（一次快速空解码），超大批量时会多花一些时间。

## 自定义（脚本顶部变量）

```bat
set "FF=D:/software/ffmpeg/bin/ffmpeg.exe"   REM ffmpeg 首选路径，缺失回退 PATH
set "FP=D:/software/ffmpeg/bin/ffprobe.exe"  REM ffprobe 首选路径
set "OUTDIR=%USERPROFILE%\Desktop"           REM 输出目录
```

## License



```text
MIT License
Copyright (c) 2026 Chevy Yang
```
