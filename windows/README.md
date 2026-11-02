# Windows 版 Codex 额度提醒

Windows 10/11 x64 系统托盘应用，采用原生 WinForms，界面与 macOS 版保持深色、青绿色风格。发布版为自带 .NET 运行时的单文件 `CodexResetBar.exe`，无需另外安装 .NET，也不需要管理员权限。

## 使用

1. 从项目 GitHub Releases 下载 Windows x64 EXE，放在固定目录后双击。
2. 本机需已安装并登录 Codex CLI。应用自动查找 `codex.exe` / `codex.cmd`；找不到时，在“提醒设置”选择现有 CLI。程序不会代装 CLI。
3. 点击系统托盘图标查看额度、剩余百分比、预计重置时间和错误状态。额度每 60 秒刷新，节点与任务事件每 15 秒检查。读取失败会保留最近成功读取的数据并明确提示。
4. 关闭主窗口会隐藏到系统托盘。完全退出请使用“退出监测”。“登录时启动”只修改当前用户的 Windows 登录启动项。
5. “关键节点提醒”最多保存 30 条，可配置额度阈值、预计重置前、指定时间、任务完成、执行步骤报错、任务提问 / 待确认。每条规则可编辑文案和声音、弹窗、手机通知，也可“测试所选规则”并查看各通道的发送结果；测试带明确标记且受主开关约束。首次观察与历史任务不触发补发；任务通知只由已验证的本机事件触发。预计重置提醒不能代表额度已经恢复。
6. 重复声音每 5 秒播放一次。通过弹窗按钮、托盘菜单或概览中的“停止提醒”确认后停止。关闭提醒弹窗也会确认并停止当前提醒。

“打开 Codex 终端”启动已选定或自动找到的 Codex CLI。程序不会发起模型调用，也不直接读取认证文件。

## Bark 手机推送

在“iPhone / Bark 推送”填写官方 Bark 地址或设备 Key，可编辑实际额度恢复的通知标题、正文，并单独发送测试。节点规则使用各自的文案。发送状态区分服务接受、服务拒绝、超时和无法确认的响应；服务接受并不等于手机已送达。

配置保存在 `%LOCALAPPDATA%\CodexResetBar\state.json`。Bark Key 仅保存为 Windows DPAPI `CurrentUser` 加密密文，绑定当前 Windows 用户；程序不记录、不显示已保存的原始 Key。删除 Key 会关闭手机推送。复制此配置到另一台机器或其他用户后，需重新配置 Key。设置文件还包含本地规则、去重状态和额度账户标识，不应用作公开日志上传。

应用使用固定的官方 HTTPS Bark 推送端点并拒绝重定向。不会因为缺少额度或未知任务状态发送“已恢复”或“任务完成”等推测通知。

## 构建

需要 .NET 10 SDK；使用 SDK 支持的系统可交叉构建，在 Windows 执行 UI / DPAPI 测试。

```powershell
dotnet run --project windows/CodexResetBar.Core.Tests -c Release
dotnet publish windows/CodexResetBar/CodexResetBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist/windows-x64
```

发布结果为 `dist/windows-x64/CodexResetBar.exe`。交叉构建成功只能验证编译与打包，不能替代 Windows 中的窗体、音频、托盘或实际 Codex 登录行为验证。

## 离线自检与只读诊断

```powershell
# 隔离的离线 Windows UI / 加密自检；退出码 0 表示通过。
$p = Start-Process -FilePath .\CodexResetBar.exe -ArgumentList '--self-test' -Wait -PassThru
$p.ExitCode

# 只读查询真实额度，不显示账户标识，不发起模型任务。
.\CodexResetBar.exe --probe
.\CodexResetBar.exe --probe --codex-path 'C:\path\to\codex.exe'
```

`--self-test` 使用临时目录和虚构 Key，不读取已有配置、认证文件或 Codex 会话，不启动常规监测，不联网、不播放声音、不触发真实通知。它验证 DPAPI 加密持久化往返、损坏配置备份保留、主窗与关键按钮、全部规则类型编辑器、通过 stub 验证单条规则测试及主开关、弹窗关闭确认与替换行为、二维码与许可资源、额度渲染和关闭隐藏行为；结束后清理临时目录。Windows CI 在发布 EXE 上执行此检查。如设置 `CODEX_SELF_TEST_ARTIFACT_DIR`，自检会仅将测试数据的概览、主设置、Bark、规则、关于界面截图复制到该目录，供渲染验收；临时配置仍会清理。

`--probe` 调用本机 Codex 的只读额度接口，输出套餐、是否允许普通用量、额度窗口和重置时间；仅输出安全错误说明。GUI 子系统程序的命令行输出宜通过父进程重定向捕获，退出码 0 / 2 分别表示成功 / 读取失败。

## 许可与联系

仅限个人非商业使用；商业使用需取得开发者书面授权。开发者微信：`wubenxincom`。应用“关于 / 联系与商业授权”中提供微信号复制按钮与原始二维码。

单文件 EXE 内嵌应用许可、.NET Runtime 与 Windows Forms 许可、.NET 第三方声明，可在“关于 / 联系与商业授权”中的“查看许可与第三方声明”阅读。
