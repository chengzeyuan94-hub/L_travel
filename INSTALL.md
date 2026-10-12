# 安装与数据

下载指定版本Release及同页SHA256SUMS：macOS使用 `LTravel-0.2.4-public.1-macOS-universal.dmg`（如提供ZIP，文件名中的平台/架构相同）；Windows使用 `LTravel-0.2.4-public.1-Windows-x86_64.zip`；Android使用 `LTravel-0.2.4-public.1-Android-arm64-v8a.apk`，独立工坊为 `LTravel-Workshop-0.2.4-public.1-Android-arm64-v8a.apk`。Source code ZIP不是安装包。

macOS：打开DMG，把游戏及工坊.app拖到Applications再启动。包为ad-hoc签名、未Apple公证；系统可能要求在系统设置「隐私与安全性」按用户选择允许打开。项目不自动更改Gatekeeper、不要求关闭安全保护。支持Apple Silicon与Intel二进制；本轮仅Apple Silicon Mac引擎测试，Intel未实机验证。

Windows：把整个ZIP解压到一个目录，双击游戏或Workshop.exe；相应.pck与.exe保留在同目录。Windows x86_64、支持Vulkan的显卡/驱动；未代码签名、无Windows实机验收。

Android：arm64-v8a、兼容Godot4.7移动渲染器的设备。下载并由用户在自己的设备选择安装APK；项目不自动更改安装来源设置。游戏与工坊不同应用ID、各自数据隔离，没有Play商店发布/签名身份。未Android实机安装与触控验收。工坊独立Android实例/试玩返回仍需设备复核，不把导出验证当实测。

首次使用：先打开工坊新建地图、放城市、接路线、保存并重开。游戏标题可以进入四幕旅行，无需胜场解锁。正式商旅和工坊试玩需「配置玩法规则」，参见RULES_CONFIGURATION.md；本版本不提供原牌或未经确认的替代默认经济。

桌面程序的数据目录为 `<OS.get_data_dir()>/LShuTravel-Open-v0.2.4`，工坊和游戏共享公开版目录；macOS通常在 `~/Library/Application Support/`，Windows通常在用户AppData/Roaming。Godot内部user://也用独立公开版名称，避免覆盖私人版本。Android数据属于各应用私有目录；游戏ID `com.chengzeyuan.lshutravel.public.game`，工坊ID `.public.workshop`，跨应用分享需使用导出/导入文件。

同ID/同签名的Android更新通常保留数据；卸载会清除应用私有数据，系统备份未启用，也未要求保留卸载数据。升级、卸载或换设备前通过工坊导出地图并单独备份规则文件。不同签名或ID不能假定继承旧存档。不要自动导入作者的旧私人地图/经济/角色资产；旧地图若内嵌原牌或私人IP，不适合再公开。

发布签名私钥不在源码或附件内。自行编译需自己的签名；作者后续发布需保留同一私钥。SHA256SUMS用于检查下载内容，与来源信任/权限选择分别判断。
