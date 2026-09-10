# H.265 QSV Batch Converter

基于 **Intel Quick Sync（QSV）**的 Windows 批量转码脚本：把当前目录下所有 `*.mp4` 一键转为 H.265/HEVC，支持 90° 旋转、分辨率封顶、码率自适应和音频自动增益，封面原样保留。

典型场景：手机录像方向纠正、老视频统一压成 H.265 省空间、音量偏小的录像自动拉满到不削顶。

> **编码器路线会自动协商**：脚本在第一个文件上依次尝试「全 GPU → QSV 硬解 + CPU 滤镜 → 纯软件」三条路线，成功后锁定，后续文件沿用。驱动/ffmpeg 组合不同也能跑通。

---

## 功能特性

- **三级编码器路线自动降级**（详见[编码器路线](#编码器路线自动降级)）
  - mode 1 全 GPU：QSV 解码 → `vpp_qsv`/`scale_qsv` → `hevc_qsv`
  - mode 2 混合：QSV 解码 → `hwdownload` → CPU 旋转缩放 → `hevc_qsv`
  - mode 3 软件：CPU 解码 → CPU 滤镜 → `libx265`
- **批量处理**：遍历**当前目录**下所有 `*.mp4`，逐个转码并汇总 `OK / FAIL / SKIP`
- **三种旋转模式**：顺时针 90°（默认）/ 逆时针 90° / 不旋转
- **分辨率封顶与方向无关**：长边 ≤ `MAXW`、短边 ≤ `MAXH`，横屏竖屏源都不会被误缩小
- **码率自适应**：沿用源码率、`BRCAP` 封顶，`maxrate = 1.2×`、`bufsize = 2×`
- **音频自动增益**：扫描峰值后放大到 0 dBFS，上限 `MAXGAIN` dB；已接近满度则直接复制
- **封面跟随旋转**：转码含旋转时，封面与画面同步旋转/缩放（重编码为高质量 mjpeg）；不旋转时原样复制
- **静默失败兜底**：退出码之外还校验输出文件大小，避免 `frame=0 / exit 0` 被误判为成功
- **ffmpeg 双路径查找**：优先内置路径，缺失回退 PATH

## 环境要求

| 项    | 要求                                                            |
| ---- | ------------------------------------------------------------- |
| 操作系统 | Windows（`.bat` / cmd 脚本，不依赖 PowerShell）                       |
| 硬件   | Intel 核显（可选，没有也能跑，会落到软件模式）                                   |
| 软件   | ffmpeg、ffprobe（需包含 `hevc_qsv`；没有 QSV 时会自动用 `libx265`）         |

> NVIDIA / AMD 独显可以跑 mode 2 / 3，想全 GPU 需自行换成 `hevc_nvenc` / `hevc_amf`。

## 使用方法

把 `convert_h265.bat` 放进视频所在目录，双击运行，或在该目录打开 cmd：

```bat
:: 直接运行，按提示输入旋转方式（直接回车 = 顺时针 90°）
convert_h265.bat

:: 用参数跳过提问：
convert_h265.bat 1   REM 1 = 逆时针 90°
convert_h265.bat 2   REM 2 = 不旋转（仅缩放/转码）
```

输出示例：

```text
Source : "D:\videos\"
FFmpeg : "D:/software/ffmpeg/bin/ffmpeg.exe"
Output : "C:\Users\you\Desktop\"
Rotate : clockwise 90
Cap    : long side 1920 / short side 1080, bitrate cap 5000k
Audio  : auto max no-clip gain, ceiling 24 dB
Cover  : 1 (1 = keep attached_pic, rotated with the video)
----------------------------------------
[CONV] "VID_0001.mp4" : bitrate 4200k (peak 5040k), rotate clockwise 90, audio +6.3dB @ 128k
[PROBE] negotiating encoder path on the first file...
[PROBE] mode 2 locked: hybrid (qsv decode, CPU filter, hevc_qsv)
[OK] "VID_0001.mp4" (1478014 bytes)
----------------------------------------
All done. OK=1  FAIL=0  SKIP=0  (encoder mode 2)
```

**输出位置**：`%USERPROFILE%\Desktop\`（可用 `OUTDIR` 改）。与源文件同名；已存在则 `[SKIP]`，可安全重复运行。

> 输出目录刻意与源目录分开。如果把输出直接放在桌面上，桌面上的任何同名文件都会让对应视频被静默跳过。

## 编码器路线自动降级

| 模式 | 链路 | 适用 |
|---|---|---|
| 1 全 GPU | `-hwaccel qsv -hwaccel_output_format qsv` → `vpp_qsv` → `hevc_qsv` | 驱动较新，QSV 滤镜可用 |
| 2 混合 | `-hwaccel qsv` → `hwdownload,format=nv12` → CPU 滤镜 → `hevc_qsv` | QSV 滤镜不可用但 QSV 编码可用 |
| 3 软件 | CPU 解码 → CPU 滤镜 → `libx265` | 无 Intel 核显 / QSV 完全不可用 |

- 协商只在**第一个文件**上做，成功后锁定，后续文件直接用同一模式
- 想跳过协商，把 CONFIG 里的 `FORCE_MODE` 设成 `1` / `2` / `3`
- **为什么需要降级**：ffmpeg 9（2025-08 之后）与部分旧版 Intel 驱动 / oneVPL 运行时组合下，`vpp_qsv` 和 `scale_qsv` 会以 `Could not create the texture (80070057)` 失败，退出码 `-1313558101`。此时 QSV 硬解和硬编本身仍是好的，走 mode 2 只把滤镜挪到 CPU，速度依然远快于纯软件
- **`-low_power 1`** 在同一批旧驱动上会让 `hevc_qsv` 报 `some encoding parameters are not supported by the QSV runtime`（退出码 `-40`）。它只用于 mode 1，出问题把 CONFIG 里的 `LOWPOWER` 改成 `0`

## 转码策略说明

| 维度   | 策略                                                                   |
| ---- | -------------------------------------------------------------------- |
| 视频编码 | H.265/HEVC（`hevc_qsv`），`-preset veryfast -extbrc 1`；软件模式 `libx265 -crf 23` |
| 视频码率 | 视频流码率 → 容器码率 → 兜底 3500k 三级回退，最终封顶 `BRCAP`；`maxrate=1.2×`、`bufsize=2×` |
| 分辨率   | 长边 ≤ 1920、短边 ≤ 1080，保持比例、不放大、宽高取偶数                             |
| 旋转   | `transpose` 在 GPU（mode 1）或 CPU（mode 2/3）完成                        |
| 帧率   | 保持源帧率，不重采样                                                           |
| 音频增益 | `volumedetect` 扫描峰值 → 最大无削顶增益（上限 `MAXGAIN` dB）→ `volume` 滤镜          |
| 音频编码 | 需要增益时转 AAC，码率取源音频码率并钳制在 64–192k；无需增益时 `-c:a copy`                    |
| 封面   | 始终探测 v:0 是否封面（`KEEPCOVER=0` 时也探测，否则封面在前的文件会把封面当主视频流编码、真视频被丢掉）。`KEEPCOVER=1` 时：含旋转则封面挂与画面相同的 `transpose+scale` 滤镜并重编码为 mjpeg（`-q 2`），方向/尺寸与画面一致；不旋转则 `-c copy` 原样保留。`=0` 时丢弃封面流                     |
| 封装   | MP4 + `+faststart` + `hvc1` tag（Apple 设备可播）                        |

## 自定义（脚本顶部 CONFIG）

```bat
set "OUTDIR=%USERPROFILE%\Desktop\"   REM 输出目录（不要和源目录相同）
set "MAXW=1920"                           REM 长边上限
set "MAXH=1080"                           REM 短边上限
set "BRCAP=5000"                          REM 视频码率封顶 kbps
set "BRDEFAULT=3500"                      REM 探测不到码率时的兜底值
set "MAXGAIN=24"                          REM 音频增益上限 dB
set "CRF=23"                              REM 软件模式 libx265 质量
set "LOWPOWER=1"                          REM mode 1 是否用 -low_power 1
set "ASK=1"                               REM 0 = 不提问（计划任务/管道场景）
set "KEEPCOVER=1"                         REM 0 = 丢弃封面
set "FORCE_MODE="                         REM 留空自动协商，或写死 1/2/3
```

## 已知限制与踩坑记录

### 分辨率表达式为什么用 `max()` / `min()`

`vpp_qsv` 是**先按 `w`/`h` 缩放、再执行 `transpose`**，所以表达式里的 `iw`/`ih` 是旋转**前**的尺寸，最终输出为 `(h, w)`。

早期版本写死 `min(1,min(1080/ih,1920/iw))`，等价于「把原始帧塞进 1920×1080 横屏框再旋转」：

| 源 | 旧表达式 | 现表达式 |
|---|---|---|
| 横屏 1920×1080 | 1080×1920 ✓ | 1080×1920 ✓ |
| **竖屏 1080×1920** | **1080×606**（只剩 31% 像素）✗ | 1920×1080 ✓ |
| 4K 横屏 3840×2160 | 1080×1920 ✓ | 1080×1920 ✓ |

改成方向无关的长短边约束后横竖都正确：

```bat
set "SC=min(1,min(%MAXW%/max(iw,ih),%MAXH%/min(iw,ih)))"
```

不旋转模式（`ROT=2`）同理：旧表达式把横屏源塞进竖屏框，1280×720 会被压到 1080×606，现在保持 1280×720。

### cmd 的几个坑（改这个脚本务必先看）

1. **`%ERRORLEVEL%` 和 `if errorlevel` 不能在括号块里读**。cmd 解析 `if (...)` 块时会一次性展开所有 `%VAR%`，块内读到的永远是进入块之前的旧值。脚本里所有退出码判断都放在块外。
2. **`if errorlevel 1` 的含义是「≥ 1」，读不到负的退出码**。ffmpeg 在 QSV 滤镜失败时返回 `-1313558101`，用 `if errorlevel 1` 判断会被当成成功。脚本统一用文本比较 `if not "%ERRORLEVEL%"=="0"`。
3. **`call` 传参时 `^` 会被翻倍**。`call :sub "a ^ b.mp4"` 里子程序收到的 `%~1` 是 `a ^^ b.mp4`，与磁盘文件名不再匹配。脚本因此不通过参数传路径，改用变量：`for %%f ... do ( set "IN=%%~ff" & call :process )`。
4. **`set "VAR=-i "%PATH%""` 这种嵌套引号写法是地雷**。展开后路径落在未加引号的区域：文件名带 `(` `)` 会截断括号块（报 `\file was unexpected at this time`），带 `&` 会拆分命令且变量被**静默截断**。正确写法是无引号 set 形式 `set VAR=-i "%PATH%"`——路径完整处于单一引号区内，`(` `)` `&` `^` 空格全部安全（均已实测）。

### 其它

- **`find` 不能用来抓 `volumedetect` 输出**：Git Bash / Cygwin / MSYS2 放进 PATH 后，它们的 `find` 会抢先。脚本用 `findstr`。
- **`-noautorotate`**：ffmpeg 5.1+ 会按旋转元数据自动插 `transpose`，软解路径会生效、QSV 硬解路径当前不生效——这是版本相关行为，脚本显式关掉，避免手机竖拍视频被双重旋转。
- **`set /p` 在非交互 stdin 下会永久挂死**（计划任务、管道、部分 CI）。这类场景请传参数（`convert_h265.bat 1`）或设 `ASK=0`。
- **每个文件要多跑一遍音频峰值扫描**（一次纯音频空解码），超大批量时会多花时间。
- **封面旋转为什么要用第二个输入**：`-hwaccel qsv` 会把封面（mjpeg/png）也硬解成 QSV 硬件帧，CPU 的 `transpose/scale` 滤镜无法消费（报 `Impossible to convert between the formats ... src: qsv`）；因此封面取自同一个文件的第二个**不带 hwaccel** 的软解输入，三种编码模式下行为一致。封面重编码为 mjpeg `-q 2`（接近视觉无损）。
- ffmpeg 的 mp4 封装器会把 `attached_pic` 流写在文件末尾（音频之后），输出里封面流排在最后属正常现象。
- **仅处理当前目录一层**的 `*.mp4`，不递归，也不匹配 `.mov`/`.mkv`（可自行改 `for` 行的通配符）。
- 临时文件在 `%TEMP%` 且带 `%RANDOM%` 后缀，多开实例不会互相踩。

## License

```text
MIT License
Copyright (c) 2026 Chevy Yang
```
