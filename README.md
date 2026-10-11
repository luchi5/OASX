# OASX 主脚本兼容版

这是面向 [OnmyojiAutoScript](https://github.com/luchi5/OnmyojiAutoScript) 的 Flutter 图形客户端，基于 [AzurTian/OASX v0.3.9](https://github.com/AzurTian/OASX) 的界面与 GPL-3.0 源码。它提供任务工作台、参数编辑、实时日志、统计、按账号查看错误档案、庭院多选和配置导入导出。后端和 [网页面板](https://github.com/luchi5/OAS-WebPanel) 分别维护。

2026-10-11：与 OAS 最新定制任务一起核对，补齐“彼世逢魔”菜单、配置组及按名称绿标的中英文标签。任务及参数仍由后端提供，不改个人目录、连接配置或启动行为。本仓库提供源码，使用新标签需要重新编译客户端。

兼容基线为 `e05492c5ff0454780ccb12b1ff945c1d944710ee`，保留上游 Git 历史。本 fork 固定兼容接口，自动更新和安装功能已关闭；后续升级需检查与主脚本的协议兼容。版本号沿用上游构建配置，来源与修改范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 环境与开发

使用 Flutter **3.35.1**、Dart **3.9.0**。Windows 原生构建还需要 Flutter 支持的 Visual Studio C++ 桌面开发工具。安装 Flutter 后执行：

```powershell
flutter pub get --enforce-lockfile
flutter analyze lib
flutter test
flutter run -d windows
```

`lib/` 是 Dart 源码，`assets/` 是必要图标和字体，`test/` 是离线回归测试，各平台目录是 Flutter 原生工程。仓库不包含 SDK、Python、后端、用户配置或编译程序。

## 配置与使用

首次运行默认连接 `127.0.0.1:22289`，账号和密码为空。请在设置页填写自己运行的 OAS 地址与凭据。自动部署、自动登录、开机自启、自动启动任务均默认关闭。“退出程序时结束 OAS 服务”默认关闭，启用后真正退出客户端会请求当前连接的后端结束服务和任务。

桌面客户端为当前后端读取本机错误档案时，需要先通过错误面板的文件夹按钮选择对应 OAS 根目录。此选择按后端地址单独保存；仓库没有预设任何开发者机器目录。远程后端的错误档案须复制到本机后再选择其目录。统计、庭院多选和导入导出依赖相应后端接口；不支持的接口会显示能力提示。

Windows 发行版使用独立 `profile-oasx/` 保存设置、缓存和日志，预览版使用 `profile-preview/`。这些目录及账户凭据都属于用户本机数据，不应提交到 Git。

## Windows 构建

使用标准 Flutter 原生构建，重新编译匹配的原生插件：

```powershell
& .\dev_tools\build_windows.ps1
& .\Start-OASX.ps1
```

构建输出在 `dist/release/`，可以运行 `start-oasx.cmd`。Flutter 不在 PATH 时，用 `-Flutter` 指定 `flutter.bat`。构建脚本不会复用预先下载的二进制运行时；发布时请另行打包 `dist/release/` 并同时提供对应源码。其他平台可使用标准 `flutter build apk`、`flutter build web` 等命令。

## 离线预览

预览服务只使用内存演示数据，独立监听 `127.0.0.1:22391`，不访问真实后端、游戏或模拟器。需要额外的 Python 3.12 与预览依赖：

```powershell
python -m pip install -r .\dev_tools\requirements-preview.txt
& .\dev_tools\build_windows.ps1 -Preview
& .\dev_tools\start_preview.ps1 -Python python
```

预览版输出在 `dist/preview/`，退出界面后演示服务仍可继续提供预览。关闭演示 Python 进程即可清除其内存修改。

## 验证

```powershell
flutter test
flutter test --dart-define=OASX_PREVIEW=true
python -B -m unittest discover -s dev_tools -p test_ui_preview_server.py
```

测试使用模拟接口、内存数据或独立临时目录，不读取用户后端配置或启动游戏。本仓库目前提供源码，Windows 程序按上面的构建步骤生成；尚未配置 GitHub Actions 自动发行流程。

## 许可证

GPL-3.0，详见 [LICENSE](LICENSE)。保留上游版权、完整源代码与依赖许可；图标及字体来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
