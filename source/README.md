# Codex 皮肤廊

本机独立环境：Node.js v26.3.0（F:/node.exe），Windows PowerShell 5.1。代码只使用 Node 内置模块与 Windows 系统组件；最低需要 Node22，不依赖 DeepSeek Harness 的运行时或包缓存。

安装位置：D:/CodexSkin；桌面原有 Codex 皮肤廊 快捷方式调用该位置的 launcher.ps1。引擎与主题库使用现有 CodexDreamSkin 安装，保留原主题。

## 启动

双击原有快捷方式。也可在 PowerShell 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:/CodexSkin/launcher.ps1
```

开发副本只用于测试，原安装变更前应备份。

## 使用

- 在线主题：搜索或粘贴官方主题链接，查看平台兼容性，下载并保存。保存不会启动或重启Codex。
- 已保存：直接读取本机主题库，断网仍可浏览和应用。应用动作会提前说明重启行为。
- 任务状态：下载、校验、保存、应用由本地服务执行，页面显示实际结果，失败可重试。
- 雨过青瓷原包仅声明macOS。Windows本地适配将使用独立ID和名称，保留原包、作者许可及来源，通过现有引擎校验。

## 测试

Node26测试使用不隔离模式，避免额外启动测试子进程：

```powershell
node --test --test-isolation=none helper/tests/*.test.js app/tests/*.test.js workers/test-launcher.test.js
```

Node22可使用常规 node --test（不受DSH沙箱限制的独立终端中）。实际引擎验收与部署记录见上级工作目录的最终验收记录。

## 数据与回滚

真实主题保存在 `%LOCALAPPDATA%/CodexDreamSkin/themes`，当前主题在 `active-theme`；皮肤廊不另建主题库。皮肤廊自己的运行数据在安装目录 `D:/CodexSkin/data`：

- 来源映射：`data/installed.json`（只记录来源版本与是否本地适配，不复制主题）。
- 任务请求与结果：`data/jobs/`（内存任务在服务重启后不完整恢复）。
- 原始主题包与适配清单：`data/downloads/<原包SHA256>/`（original.zip、source-manifest.json、windows-local-manifest.json）。

不要在部署时把工作副本 `source/data` 或测试隔离 state 覆盖到正式安装；正式主题库由引擎维护。

## 部署与回滚（维护者）

部署/回滚脚本不在安装目录内，位于工作区 `D:/Dirty_work/codex-skin-audit/continuation/scripts/`，均默认预演（不加 `-Apply` 只打印计划）：

- `deploy-gallery.ps1`：只部署固定 6 项产品文件（launcher.ps1、app/index.html、app/app.js、app/styles.css、helper/gallery-helper.js、helper/engine-worker.ps1）。部署前先把现有文件备份到 `continuation/backup/deploy-<时间戳>/files/`，并**先落盘且回读校验恢复清单 manifest.json**，再对运行中的 helper 做维护准入：拒绝 queued/running 任务、拒绝未确认终止锁、拒绝 v2 任务状态查询失败，并通过服务端 `/api/maintenance` 门闩阻止检查后新增写任务；随后复核同一进程实例（PID/可执行文件/脚本参数/CreationDate/监听归属）再停止、逐文件写入并更新进度。中途失败或启动失败时清单仍在，可用回滚脚本恢复。
- `rollback-gallery.ps1 -BackupDir <备份目录> -Apply`：独立校验固定六项白名单、路径包含关系、重复项、重解析路径与文件哈希漂移；校验全部通过后才停进程、恢复原有文件、删除本次新建且未漂移的文件。回滚只恢复产品文件，不改变真实主题库，并保留部署后新增/应用的主题与当前选择。
- `rehearse-deploy.ps1`：在临时目录与隔离主题库演练正常部署、中途失败、启动失败、越界/重复/漂移拒绝与主题保留，不触碰正式安装。
- 备份目录名含毫秒与随机后缀，避免重复运行冲突。停止 helper 前会核实 Node 可执行文件与精确脚本参数；无法确认身份则拒绝停止。

部署会停止并（在 `-Launch` 时）重启该皮肤廊本地服务，以加载新代码；不会停止 Codex injector 或托盘进程。回滚六项产品文件后重启即可恢复旧版界面。
