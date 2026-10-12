# 构建公开版

完整clone包含 `generated/traveler`。这些运行资源已入库，游戏导出不需要恢复私人ZIP或重新购买/生成模型。不要删除generated后把失效资源当作构建成功。可选美术制作脚本的上游工程和旧研究记录不属于运行构建要求；部分旧设计工具需Blender、Pillow/NumPy或外部生成服务，并不保证全部历史研究流程可重跑。

需要 Godot **4.7.1 stable** 和同版官方export templates，Python3（发布脚本仅标准库）。从提交干净的工作树运行：

```sh
python3 tools/build_public_release.py --godot /path/to/godot --target 'macOS' --target 'macOS Workshop'
python3 tools/build_public_release.py --godot /path/to/godot --target 'Windows' --target 'Windows Workshop'
```

Android：JDK17、Android SDK及build-tools（本轮本机35.0.1），在Godot Editor Settings的Export/Android填写本地SDK/JDK路径。使用非Gradle官方APK模板。为自己的应用建立并妥善保管发布keystore；在本地环境设置 `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`、`GODOT_ANDROID_KEYSTORE_RELEASE_USER`、`GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD`，再执行Android和Android Workshop两个target。不要把密钥/密码写进预设、命令历史、Git或构建日志。作者正式APK更新必须复用作者专用签名，不能用自己的签名覆盖安装。

默认输出builds/public/，会生成ignored的BUILD_INFO.json，记录同一源码commit/tag；各平台日志和build-manifest保留。macOS app需将两款.app打包到DMG/ZIP；Windows两款.exe及各自同名.pck必须同时打包，不能只发.exe；Android游戏/工坊分别生成APK，应用ID不同。

本轮macOS导出Universal（arm64+x86_64），ad-hoc签名，未公证；Windows未签名。不要将ad-hoc写为Developer ID，也不要把模板包含Intel架构当Intel实机通过。Android包需用apksigner验证，所有附件用SHA256校验。构建成功不是实机验收。

无窗口公开版回归（使用临时独立数据目录）：

```sh
SILKROAD_DATA_DIR=/absolute/temp/qa godot --headless --path . res://tests/public_release_tests.tscn
```

29项检查覆盖空规则门禁、真实保存重开、配置导入、合成自有规则开局/交易、错误配置保留。测试用合成参数仅在隔离目录临时生成；不作为游戏默认。四幕依赖探针：`godot --headless --path . --script res://tools/release_preflight.gd`，也需独立SILKROAD_DATA_DIR。
