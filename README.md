# 直接操作你的华硕ProArt风扇

## 一键全速，直达 6300 RPM

**在 ASUS ProArt Studiobook H7600ZW 上，CPU / GPU 风扇均实测达到过 6300 RPM，稳定阶段保持在 6200–6300 RPM。** 针对直接切换全速后转速上不去的情况，程序自动执行模式切换恢复，并持续检查两侧实际转速。

[![一键下载 Windows EXE](assets/download-exe.svg)](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect.exe)

**[点击直接下载 AsusFanDirect.exe](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect.exe)** · [版本说明与校验值](https://github.com/batai1222/asus-fan-direct/releases/latest)

下载后双击 EXE，在 Windows 管理员权限提示中确认，即可打开中文控制窗口。无需解压、安装或输入命令；运行环境使用 Windows 自带的 Windows PowerShell 5.1 和 .NET Framework 4.x。

6300 RPM 是已验证机型的实测峰值，稳定记录存在 6200–6300 RPM 的正常波动，不代表所有机型或负载下都恒定锁在 6300 RPM。

一个用 Windows PowerShell 编写的轻量 ASUS 风扇控制工具，提供中文图形界面和命令行入口，可切换**全速、高速、安静**三种固件预设，并读取 CPU / GPU 风扇实际转速。

当前版本：**2026.09.19.2**。已在 **ASUS ProArt Studiobook H7600ZW** 上验证。

## 功能

- **全速**：依次执行普通 → 高速 → 全速，处理该机型直接进入全速后转速未充分提升的问题；图形界面保留 30 秒升速时间，并限制恢复次数。
- **高速**：直接切换到固件的性能模式。
- **安静**：从高转速进入安静时，先用高速模式过渡；两侧均降至 2500 RPM 以下或达到约 12 秒的过渡期限后进入安静。实际降速取决于负载和温度。
- **实时监测**：显示当前模式及 CPU / GPU 风扇转速；读取失败时显示状态异常。
- **稳定后关闭窗口**：图形界面在目标状态稳定 60 秒后自动关闭。全速判定包含 GPU 首次达到 6300 RPM、随后保持 6200–6300 RPM，以及 CPU 至少 6200 RPM 的条件。
- **单实例控制**：同一登录会话中只允许一个控制实例；只读状态查询可以同时进行。

## 使用条件

- Windows，使用系统自带的 **Windows PowerShell 5.1**。
- 以管理员身份运行控制命令。
- 系统中需要存在 ASUS 驱动提供的 `root\WMI` / `AsusAtkWmi_WMNB` 接口。
- 目前实机验证范围只有 **H7600ZW**；其他机型的接口、模式值及转速阈值可能不同。

这是个人开发的非官方工具。它切换固件预设，不提供任意 RPM 或自定义风扇曲线；其中的转速阈值针对已验证机型。使用前确认机型兼容，避免与其他风扇控制软件同时改写模式。

## EXE 快速开始

1. 点击上方“**一键下载 EXE**”按钮，保存 `AsusFanDirect.exe`。
2. 双击运行，并确认管理员权限提示。
3. 点击“**全速**”，查看 CPU / GPU 实际转速；也可以选择“高速”或“安静”。

EXE 内置本仓库的控制脚本，不需要另外下载 PS1，也不会创建开机启动项。当前 EXE 尚未代码签名，Windows 可能显示“发布者未知”。

## 从源码运行

1. 点击仓库的 **Code → Download ZIP** 并解压，或克隆仓库。
2. 以管理员身份打开 **Windows PowerShell**，进入解压后的项目目录。
3. 运行：

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Gui
```

然后在窗口中点击“全速”“高速”或“安静”。`ExecutionPolicy Bypass` 仅用于这次 PowerShell 进程，不修改系统执行策略。

EXE 与脚本使用相同的风扇控制逻辑。关闭窗口会结束监测，不会主动恢复之前的模式；如果关闭时仍在安静过渡中，会尝试完成安静切换。后续模式仍可能受到固件或其他 ASUS 软件影响。

## 命令行

在管理员 Windows PowerShell 中运行以下命令：

```powershell
# 只读取状态，不切换模式；可与已打开的窗口共存
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Status

# 切换到全速
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Full

# 切换到高速
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode High

# 切换到安静（可能等待降速过渡完成）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Quiet
```

命令行完成切换后退出；持续监测、全速恢复重试及稳定后自动关闭是图形界面的行为。运行控制命令前先关闭已有控制窗口。

## 测试

仓库包含既有的 54 项模拟检查，覆盖模式切换顺序、异常收尾、重试上限、传感器读取失败、安静过渡取消、窗口关闭和自动关闭判定。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FanController.ps1
```

测试使用模拟的硬件调用，不写入真实风扇模式；通过模拟检查不等于验证所有机型兼容。

## 自行构建 EXE

在 Windows PowerShell 5.1 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1
```

脚本调用 Windows 已安装的 .NET Framework C# 编译器，将控制脚本和模拟检查嵌入单个 x64 EXE，自动运行无硬件写入的自检，输出到 `dist/`。不需要下载打包工具。

开发者也可以执行 `AsusFanDirect.exe --self-test`：运行嵌入的 54 项模拟检查并返回退出码，不申请管理员权限，也不控制真实风扇。

## 文件

| 文件 | 用途 |
| --- | --- |
| `AsusFanDirect.ps1` | 主程序，包含图形界面和命令行入口 |
| `tests/Test-FanController.ps1` | 无硬件写入的模拟检查 |
| `CHANGELOG.md` | 已有版本的修改记录 |
| `launcher/Program.cs` | 单文件 EXE 的启动与权限处理 |
| `build/Build-Exe.ps1` | 本地构建与自检入口 |

## 常见问题

**找不到 `AsusAtkWmi_WMNB` 或读取失败**：检查 ASUS 系统控制相关驱动及机型支持情况。此工具不会安装驱动。

**提示已经运行**：使用现有窗口中的按钮，或先关闭现有控制实例，再运行新的控制命令。

**全速未达到目标或安静模式仍有较高转速**：实际转速由固件、温度和负载共同决定。工具显示实测转速，不保证在任何负载下达到固定转速。

## 许可

本仓库暂未添加开源许可证。
