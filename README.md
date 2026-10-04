# 直接操作你的华硕ProArt风扇

**2026.10.04.1 · 三档风扇控制 · 达速一分钟后收起到托盘**

面向 ASUS ProArt Studiobook **H7600ZW** 的个人工具。显示 CPU / GPU 实际转速，提供“高速后安静”“6300 转”“7000 / 6500 转”三档，支持托盘保持和 Fn+F 让出控制。

本机增强档实测：**CPU 约 7000 RPM，GPU 约 6400–6500 RPM**。未观察到 GPU 7000 RPM；这些是有限时长的本机结果，其他机型与负载下没有验证。

## 下载与安装

**[下载完整 Windows x64 安装包](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect-2026.10.04.1-win-x64.zip)** · [发布说明与 SHA-256](https://github.com/batai1222/asus-fan-direct/releases/latest)

1. 下载 ZIP 并全部解压。如果旧版正在运行，先从程序中点击“退出程序”。
2. 右键 `Install.cmd`，选择“以管理员身份运行”。
3. 打开桌面上的小风扇快捷方式，选择档位。

增强档需要 `GpuSaioWorker.ps1` 和一个 **SYSTEM 权限的按需后台任务**。安装器将文件复制到 Program Files，并创建这个任务与桌面快捷方式；不会启动风扇控制或创建开机启动项。首次安装请使用完整 ZIP。

[单独下载 EXE](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect.exe) 供已经安装后台组件的用户更新。**裸 EXE 不能完成增强档的首次安装。** 更新时，EXE 与后台脚本应来自同一版本。

要求 Windows x64、Windows PowerShell 5.1、.NET Framework 4.x，以及本机已有的 ASUS 系统控制与 SAIO 驱动。项目不安装或分发 ASUS 驱动，不更改 BIOS。EXE 尚未代码签名，Windows 可能显示“发布者未知”。

## 档位与托盘

| 档位 | 行为 |
| --- | --- |
| 高速后安静 | 释放手动控制，必要时经过最多 12 秒的高速过渡，再进入安静与自动调速；降速仍需要时间 |
| 6300 转 | 使用原有整机全速方法，显示实际 CPU / GPU 读数 |
| 7000 / 6500 转 | 整机全速模式配合已验证的 SAIO 双扇最大 PWM；CPU 约 7000，GPU 约 6400–6500 |

- **达速保持 60 秒后，窗口自动收起到托盘，风扇控制继续运行。** 切档、掉速、读取失败或控制异常会重新计时。
- 自动收起判定：安静为双扇 ≤2500；6300 档为 CPU ≥6200、GPU ≥6300；增强档为 CPU ≥6900、GPU ≥6400 RPM。它们用于窗口计时，不是任意 RPM 的设置接口。
- 手动关闭窗口或点击“收起到托盘”同样只隐藏窗口。
- 双击托盘图标、菜单“打开窗口”或再次启动同版 EXE 可唤回窗口，重新等待一分钟。
- **Fn+F 切换到系统档位时，程序停止维持并释放手动控制。** 再次选择档位可接管。
- “退出程序”恢复自动调速后结束；恢复失败时保留窗口并提示重试。

收起不等于退出。不要同时运行多个风扇控制工具。升级后，已加载的旧进程仍运行旧代码；退出旧程序后再启动新版，才会使用新版行为。

## 实测范围

2026-10-01 的 H7600ZW 测试中，GPU 最大 PWM 255 稳定阶段均值约 **6464–6484 RPM**，常见原始读数为 6417–6514 RPM。隔离 ProArt / ASUSOptimization 服务未提高转速；已知测试模式标志未解开新的上限。没有观察到 GPU 7000。

自动收起逻辑通过模拟时间与模拟硬件检查；本次发布没有重新做风扇硬件实验。[详细实测与旧版记录](https://github.com/batai1222/asus-fan-direct/blob/main/docs/hardware-validation.md)。

## 源码、测试与构建

源码运行的增强档仍需先安装后台任务：

```powershell
# 管理员 Windows PowerShell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Gui

# 只读状态，不切换模式
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AsusFanDirect.ps1 -Mode Status

# 44 项模拟检查，不写真实风扇硬件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FanController.ps1

# 构建、校验内嵌源码、执行自检，并生成安装包与校验文件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1
```

构建输出在 `dist/`。`AsusFanDirect.exe --self-test` 只执行模拟检查和隐藏的桌面依赖检查，不申请管理员权限，不控制硬件。`ExecutionPolicy Bypass` 只作用于本次进程。

| 文件 | 用途 |
| --- | --- |
| AsusFanDirect.ps1 | 控制器、窗口、托盘与命令行入口 |
| GpuSaioWorker.ps1 | 命名管道、后台最大 PWM、心跳与 AUTO 释放 |
| Install.ps1 / Install.cmd | 按需后台任务与快捷方式安装 |
| launcher/ | C# 启动器与版本清单 |
| build/Build-Exe.ps1 | 构建、校验与打包 |
| tests/ | 模拟控制、倒计时与安装计划检查 |

## 许可

本仓库暂未添加开源许可证。
