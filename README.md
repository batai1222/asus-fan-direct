# 直接操作你的华硕ProArt风扇

## 安静 · 6300 · 7000：三档切换，托盘持续保持

**当前版本：2026.09.22.3。** 针对 ASUS ProArt Studiobook **H7600ZW**，提供三档中文控制界面、CPU / GPU 实际转速显示，以及关闭窗口后仍继续运行的托盘控制。

**7000 档的五分钟本机测试中，排除前 30 秒升速后，CPU 保持在 6900–7000 RPM；GPU 为 6200–6300 RPM。** 未实现 GPU 7000，也未证明 GPU 每个采样都不低于 6300。档位名称是控制目标，实际转速以窗口读数为准。

[![一键下载 Windows EXE](assets/download-exe.svg)](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect.exe)

**[点击直接下载 AsusFanDirect.exe](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect.exe)** · [版本说明与校验值](https://github.com/batai1222/asus-fan-direct/releases/latest) · [实测结果](docs/hardware-validation.md)

## 三个档位

| 档位 | 程序行为 | 已验证表现 |
| --- | --- | --- |
| **安静** | 取消全速保持，释放双扇原生强制状态，短暂进入普通模式 100 ms 后切安静，再确认 AUTO | 有降速改善，仍需数十秒；从 7000 档降至双扇 ≤2500 RPM 约 65 秒，并非瞬间静音 |
| **6300** | 解除原生强制状态，使用原有整机全速方法 | 约 60 秒测试的后半段，CPU 6200–6400 RPM、GPU 6200–6300 RPM；结束时双扇均为 6300 |
| **7000** | 使用已知原生全速命令持续保持；GPU 未达到 7000 时不再反复切整机档位干扰 CPU | 约五分钟测试升速后 CPU 6900–7000 RPM、GPU 6200–6300 RPM |

**安静流程不经过高速／性能模式 2，也不发送原生强制全速命令。** 采用的是普通模式 0 的 100 ms 短复位，然后进入安静与自动调速。35 秒附近的对照中，GPU 约 3900 RPM，而直接安静＋AUTO 约 4400 RPM；不能将此改善描述为立即低速或立即无声。

## 下载与使用

1. 点击上方“**一键下载 EXE**”，保存 `AsusFanDirect.exe`。
2. 双击运行，在 Windows 管理员权限提示中确认。
3. 选择“安静”“6300 转”或“7000 转”，观察 CPU / GPU 的实际转速。

Windows 64 位单文件程序，无需解压、安装或手动输入命令。EXE 内置控制脚本，使用系统已有的 **Windows PowerShell 5.1、.NET Framework 4.x**，并依赖 ASUS 驱动提供的 `root\WMI` / `AsusAtkWmi_WMNB` 接口。程序不会安装驱动或创建开机启动项。

当前 EXE 尚未代码签名，Windows 可能显示“发布者未知”。SHA-256 校验文件可在发布页下载。

### 关闭窗口、重新打开与退出

- **点击窗口右上角关闭，或“收起到托盘”**：只隐藏窗口，程序继续运行并维持所选档位。
- **再次双击 EXE，或双击托盘图标**：唤回已有窗口，不创建第二个控制实例。
- **点击“安静并退出”或托盘菜单“恢复安静并退出”**：恢复安静和固件自动调速后退出；恢复失败时会显示错误供重试。

本版不再达到目标后自动结束进程。更新前请退出旧版控制程序，再启动新版；已有同版实例运行时，重新启动只会唤回它，不会替换正在运行的代码。

## 实测范围与限制

以下为 **2026-09-22、H7600ZW、2026.09.22.3** 的交付验收记录，读数分辨率为 100 RPM：

- **7000 档**：连续 299.72 秒，排除前 30 秒后共 495 个样本；CPU 全部为 6900–7000 RPM，GPU 为 6200–6300 RPM。GPU 57% 样本为 6300，其余为 6200，未观察到 7000。
- **6300 档**：连续 59.78 秒，后 30 秒 CPU 6200–6400 RPM、GPU 6200–6300 RPM，结束时双扇均为 6300。
- **7000 → 安静**：约 30 秒时 CPU 2900、GPU 4300 RPM；双扇 ≤3000 用时 49.81 秒，≤2500 用时 65.17 秒。
- **6300 → 安静**：双扇 ≤3000 用时 50.25 秒，≤2500 用时 64.54 秒。

这是有限时长的本机验证，不是无限期稳定保证，也不是其他机型或所有温度、负载下的保证。不能宣称“双扇稳定 7000”“GPU 始终至少 6300”或“瞬间静音”。完整对照说明见 [实测结果](docs/hardware-validation.md)。

这是个人开发的非官方工具。档位与控制方式针对已验证机型，不提供任意 RPM 或自定义风扇曲线。避免其他风扇控制软件同时改写模式。

## 从源码运行

下载并解压仓库，在管理员 Windows PowerShell 中进入项目目录，然后运行：

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Gui
```

`ExecutionPolicy Bypass` 只作用于本次进程，不修改系统执行策略。EXE 与脚本使用同一份控制逻辑。

### 命令行

```powershell
# 只读取状态，不切换模式，可与控制窗口共存
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Status

# 持续控制 7000 档 60 秒，结束时尝试恢复安静与 AUTO
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode RPM7000 -DurationSeconds 60

# 持续控制 6300 档 60 秒，结束时尝试恢复安静与 AUTO
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode RPM6300 -DurationSeconds 60

# 切换安静并释放原生强制状态；命令结束不代表风扇已降至低速
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Quiet
```

不指定 `DurationSeconds` 或设为 0 时，6300 / 7000 命令持续运行。正常离开控制流程时会尝试恢复安静与 AUTO。兼容别名 `Full` 对应 `RPM7000`，`High` 对应 `RPM6300`。

已有控制实例运行时，新的控制命令只会唤回它，不会改变它的档位；请使用现有窗口或托盘菜单切换，或先退出已有实例。

## 无硬件写入的测试与 EXE 构建

```powershell
# 33 项模拟检查，不调用真实风扇硬件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FanController.ps1

# 构建 Windows x64 EXE 并执行嵌入自检
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1
```

模拟检查覆盖持续保持不重切整机档、GPU 读数不触发 CPU 扰动、切安静取消旧保持、双扇释放、有限重试、无效读数和托盘保持相关约束。它们不能替代其他机型的实测。

构建脚本使用 Windows 已安装的 .NET Framework C# 编译器，将源码与模拟测试嵌入单个 EXE，验证嵌入内容与仓库文件一致，输出到 `dist/`。运行 `AsusFanDirect.exe --self-test` 可执行 33 项嵌入检查与桌面依赖检查，不申请管理员权限，也不控制真实风扇。

| 文件 | 用途 |
| --- | --- |
| `AsusFanDirect.ps1` | 三档控制器、图形界面、托盘与命令行入口 |
| `tests/Test-FanController.ps1` | 33 项无硬件写入模拟检查 |
| `launcher/Program.cs` | EXE 启动、权限处理和嵌入宿主 |
| `build/Build-Exe.ps1` | 构建、内嵌源码校验与自检 |
| `docs/hardware-validation.md` | 有限时长的本机实测及限制 |
| `CHANGELOG.md` | 版本记录 |

## 常见问题

**找不到 WMI 接口或读取失败**：检查 ASUS 系统控制驱动与机型支持情况。

**关闭后风扇仍保持高速**：本版关闭窗口会收起到托盘。使用“安静并退出”恢复自动调速并结束程序。

**7000 档的 GPU 只有 6200–6300**：这是本机已观察到的结果。程序展示实际读数，不会为了 GPU 未到 7000 而反复重切整机档。

**切安静后仍有声音**：降速需要时间。验收中双扇降至 2500 RPM 以下约需 65 秒；实际时间随温度与负载变化。

## 许可

本仓库暂未添加开源许可证。
