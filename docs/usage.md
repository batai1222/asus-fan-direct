# 使用说明

1. [下载 AsusFanDirect.exe](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect.exe)，双击并允许管理员权限。
2. 首次自动配置后台组件并创建小风扇快捷方式，然后打开窗口。
3. 选择档位。同版再次运行会唤回窗口；升级时先在旧版中点击“退出程序”。

三档为“高速后安静”“6300 转”“7000 / 6500 转”。H7600ZW 实测 CPU 约7000、GPU约6400–6500 RPM；未观察到 GPU7000，其他机型和负载未验证。

达速连续一分钟后窗口收起，托盘保持调速；掉速或重新打开窗口重新计时。双击托盘图标恢复窗口，Fn+F切到系统档位时让出控制，“退出程序”恢复自动调速。

## 要求与后台

Windows x64、Windows PowerShell 5.1、.NET Framework 4.x，以及电脑已有的 ASUS 系统控制和 SAIO 驱动。EXE不分发驱动、不更改BIOS，尚未代码签名。后台按当前启动用户 SID 配置；首次与后续 UAC 应使用同一账号。

单文件EXE内置控制器、后台、安装器和图标。文件存放于受保护的 Program Files，SYSTEM 任务按需运行，没有开机启动项；目录权限和组件哈希核对一致时复用。升级不会强制关闭旧版。

[完整 ZIP](https://github.com/batai1222/asus-fan-direct/releases/latest/download/AsusFanDirect-2026.10.04.2-win-x64.zip) 可用于手动安装：全部解压后以管理员身份运行 Install.cmd。

## 构建与自测

在源码目录运行 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1
.\dist\AsusFanDirect.exe --self-test
```

自测仅使用模拟数据和隐藏的窗口依赖检查，不申请管理员权限、不安装组件、不控制硬件。构建输出位于 dist。执行策略仅作用于本次进程。

[实测记录](hardware-validation.md) · [更新记录](../CHANGELOG.md)。本仓库暂未添加开源许可证。
