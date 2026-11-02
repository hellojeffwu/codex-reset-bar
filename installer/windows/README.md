# Windows 安装包

`CodexResetBar.iss` 是 Inno Setup 标准向导安装包源码。安装仅面向当前用户，默认目录为 `%LOCALAPPDATA%\Programs\CodexResetBar`，不请求管理员权限，不自动开启登录启动。

中文“下一步”向导包含欢迎、完整许可、安装前说明、安装位置、开始菜单文件夹、可选桌面快捷方式、安装确认和完成页。完成页可选择运行应用；静默安装不会运行。安装包包含原始微信二维码、商业授权说明、应用许可及 .NET 第三方许可。

在 Windows 上先发布自包含单文件 EXE，再构建安装包：

```powershell
dotnet publish windows/CodexResetBar/CodexResetBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o build/windows
./scripts/package-windows.ps1
```

需要 Inno Setup 6.5 或更新版本。脚本优先查找已安装的 `ISCC.exe`；可通过 `-InnoSetupCompiler 'C:\path\ISCC.exe'` 指定。发布 CI 使用 `-InstallInnoSetup` 确保固定的 6.5.4：优先复用该版本，否则下载 Inno Setup 官方 GitHub 的固定 6.5.4 安装 EXE，与 Microsoft winget 的 `JRSoftware.InnoSetup` 6.5.4 清单交叉核对的固定 SHA256 完全一致后，才以当前用户 portable 模式安装至 `build/tools/innosetup-6.5.4`。无需 winget，不下载执行 PowerShell 或 shell 脚本，不写入全局文件关联或卸载注册；安装依赖需要联网。应用安装包本身无下载步骤。编译器版本通过不输出 EXE 的最小编译读取实际引擎版本，不依赖 PE 的产品版本字段。6.5.4 的[原始许可](https://github.com/jrsoftware/issrc/blob/is-6_5_4/license.txt)允许商业用途，需保留上游版权、网址及许可条件。

简体中文语言文件随源码固定保存，来自 [Inno Setup 官方源码提交 6ef3219](https://github.com/jrsoftware/issrc/blob/6ef32198ef1f7b7b375cd4b6b90896c2a58eb4c2/Files/Languages/ChineseSimplified.isl)，未修改翻译及署名；上游许可见 `LICENSE.InnoSetup.txt`，安装目录也提供其副本。语言文件仅含语言选项、消息和自定义消息，不含安装代码。它兼容 Inno Setup 6.5+，无需构建时下载额外语言包。

`-AppPath` 可指定现有已发布 EXE；`-Version` 默认从 Windows csproj 读取；`-OutputDirectory` 默认 `dist`。相对路径以仓库根目录解析。输出：

```text
dist/CodexResetBar-<version>-windows-x64-setup.exe
dist/CodexResetBar-<version>-windows-x64-setup.exe.sha256
```

在干净的 Windows CI 用户中验证安装与卸载：

```powershell
./scripts/test-windows-installer.ps1 -SetupPath dist/CodexResetBar-1.6.0-windows-x64-setup.exe -CaptureWizard
```

测试拒绝覆盖同 AppId 的已有安装和已有桌面快捷方式。它在带空格的唯一临时安装目录静默安装、检查载荷和快捷方式、再次安装验证升级并选择桌面快捷方式、运行已安装 EXE 的离线 `--self-test`、静默卸载，并比较虚构 DPAPI 配置与偏好文件的 SHA256，验证用户数据保留。不会运行常规监测或 `--probe`，不会访问真实 Codex 或发送 Bark。测试完成后只清理自己创建的虚构数据。

`-ArtifactDirectory` 可指定报告目录，默认 `build/windows-installer-test`。其中包括 `report.json`、安装/升级/卸载日志与已安装应用的离线 UI 截图。`-ExpectedAppPath` 默认 `build/windows/CodexResetBar.exe`，用于比较安装后 EXE 的哈希。可选 `-CaptureWizard` 只启动欢迎页并截图，然后终止这次新建的安装进程树；不点击任何按钮，不执行安装。截图需人工查看；静默验收不代表已完成真人交互、真实账号、音频或推送验收。

升级由 Windows Restart Manager 处理正在使用目标 `{app}\CodexResetBar.exe` 的进程，交互安装会提示关闭应用；不按进程名批量结束 Codex CLI 或宿主，也不强制关闭应用。无法安全关闭时，用户可在托盘选择“退出监测”后重试。安装完成后不会通过 Restart Manager 自动重新启动应用。

应用配置保存在 `%LOCALAPPDATA%\CodexResetBar`，独立于安装目录。安装脚本没有对该目录的写入或删除指令。卸载只移除安装过的程序文件、快捷方式及卸载注册，保留用户原有配置与 DPAPI 密文。

参考：[Inno Setup 官方安装包下载](https://jrsoftware.org/isdl.php)、[当前用户安装](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm)、[Restart Manager 关闭应用](https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm)、[文件检查范围](https://jrsoftware.org/ishelp/topic_setup_closeapplicationsfilter.htm)、[官方语言包](https://jrsoftware.org/files/istrans/)。
