# Dreamskin_more_comfotable_ui

在 DreamSkin 基础上改善主题管理反馈与操作体验的 Windows 本地皮肤廊。更清楚的中文界面、更真实的任务反馈，以及更人性化的（human-friendly）UI。

## 功能

- 在线主题搜索、链接识别与平台兼容提示。
- 下载并保存与应用分离：保存不会重启 Codex，应用前明确确认。
- 直接读取现有 DreamSkin 主题库，显示当前主题与已保存主题。
- 下载大小和 SHA-256 校验、导入结果确认、失败信息与任务状态。
- 请求取消、过期响应保护、短时缓存和同请求合并。
- 本机同源服务、写入令牌、维护门闩、备份与回滚工具。

## 目录

- `source/`：完整皮肤廊产品源码、Node 测试、引擎桥及验证工具。
- `continuation/scripts/`：部署、回滚、隔离演练和维护边界测试。

## 环境与启动

Windows、Node.js 22+、Windows PowerShell 5.1，以及已经安装且可工作的 DreamSkin / CodexDreamSkin 引擎。此仓库是现有安装的增强界面，不包含 DreamSkin 引擎、Node 运行时或 Codex 安装包，也不是全新机器的一键安装器。

本机验证使用 Node 26。启动器优先使用 `F:/node.exe`，其次查找 PATH 中的 Node 或现有 DreamSkin 运行时；使用前检查 `source/launcher.ps1` 中的运行环境路径。已有安装可将 `source/app/`、`source/helper/` 和 `source/launcher.ps1` 放入皮肤廊目录；先备份，勿覆盖用户的 `data/` 或主题库。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\source\launcher.ps1
```

默认服务地址为 `http://127.0.0.1:9336/`。应用主题可能重启 Codex，请先保存工作。

## 测试

```powershell
cd source
node --test --test-isolation=none helper/tests/*.test.js app/tests/*.test.js workers/test-launcher.test.js
```

发布准备时 Node 回归测试 50/50 通过。原生引擎测试需要本机 DreamSkin 安装及相应原包 fixture；主题包未随仓库分发。维护脚本中的默认路径来自开发环境，运行时请显式指定自己的路径。部署和回滚默认仅预演，增加 `-Apply` 才执行；保留同目录公共库。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\continuation\scripts\deploy-gallery.ps1 -SourceRoot "C:\path\to\repo\source" -TargetRoot "D:\CodexSkin" -BackupRoot "C:\path\to\backups" -ShortcutPath "C:\path\to\gallery.lnk"
```

## 来源与边界

本项目基于现有 DreamSkin 皮肤廊集成流程进行增强，感谢原项目与主题作者。DreamSkin 官网：<https://dreamskin.cc/>。不冒充官方客户端；原有代码、引擎及主题的权利与许可仍归各自权利人。仓库未额外授予第三方代码或素材的再许可。

“雨过青瓷”的 Windows 本地适配仅限代码中固定身份及哈希的原包，保留作者、许可及来源，不是官方 Windows 版本。原包、背景图片和已保存主题不上传。

已验证真实保存、API 应用及重启后渲染；用户反馈实际测试无明显问题。最终真实 UI 点击验收由用户执行，不把 API 验证等同自动化 UI 验证。部分 muted 小字的固定色对低于 AA 正文阈值，未宣称全界面可访问性合规。回滚在正式环境仅做预演，隔离失败恢复测试已通过。

不包含本机日志、浏览器 profile、个人配置、主题库、运行缓存、密钥或开发过程中的私人截图。
