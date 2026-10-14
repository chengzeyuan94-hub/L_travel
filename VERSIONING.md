# 产品 v0.1 与安装包版本的对应关系

“旅行L叔 v0.1”是这次产品定版名称。为保留已有下载、应用更新与构建追踪，程序和包继续使用既有技术版本，不将0.2.4改写成0.1，也不重写已发布tag。

| 项目 | 定版对应 |
|---|---|
| 产品名称 | 旅行L叔 v0.1 |
| 本仓库交付类型 | 公开清理版：游戏与地图工坊 |
| 程序与安装包技术版本 | 0.2.4-public.1 |
| 安装包源码tag | `v0.2.4-public.1` |
| 安装包源码commit | `09af7f35bdd892a186304a208e42f1217c367aed` |
| Android游戏/工坊versionCode | `202610121`，两应用各自独立 |
| Android游戏应用ID | `com.chengzeyuan.lshutravel.public.game` |
| Android工坊应用ID | `com.chengzeyuan.lshutravel.public.workshop` |
| 下载与校验 | [指定Release](https://github.com/chengzeyuan94-hub/L_travel/releases/tag/v0.2.4-public.1)、[SHA256SUMS](https://github.com/chengzeyuan94-hub/L_travel/releases/download/v0.2.4-public.1/SHA256SUMS)、[包清单](https://github.com/chengzeyuan94-hub/L_travel/releases/download/v0.2.4-public.1/release-manifest.json) |

`main`可以继续补充文档；这不会改变上述已冻结安装包。需要修复运行代码时，应从明确基线构建新的技术版本，保留旧包、另建tag与校验记录。Android更新须沿用同应用ID、原签名并提高versionCode。

## 公开安装包SHA256

以下四包已重新读取完整文件摘要，与既有Release清单一致；文件名和下载tag保持不变。

| 安装包 | SHA256 |
|---|---|
| LTravel-0.2.4-public.1-macOS-universal.dmg | `8b0ad3f019c236f1d6359103f7a1e909f4a44292c0c1eadc61515d52f0690206` |
| LTravel-0.2.4-public.1-Windows-x86_64.zip | `31ca6fd010f65d3ff1064264266c356f2c986b091a3b61ef71ba7d800bd44e6f` |
| LTravel-0.2.4-public.1-Android-arm64-v8a.apk | `bc9c544bda76de26b3d376d23f4684c935f61343c1b50c1957ba69a7cd720f44` |
| LTravel-Workshop-0.2.4-public.1-Android-arm64-v8a.apk | `393fce691c322f04eeea5868fad5d985a423b54b3c70f533ad15af6d50cc3535` |

## 私人版与公开版

私人完整内容与本仓库的公开清理内容是两种有意不同的交付。公开版不携带原80贸易牌数值、原事件文字、原供应与起始物资，也不携带未清权角色、私人地图、存档或签名私钥。完整商旅与试玩需要自有规则配置；地图编辑和四幕旅行可直接使用。详细范围见[CLEANUP.md](CLEANUP.md)。

产品名称统一不表示两种交付的规则、音频、动作或素材完全相同，也不将GUI未复测候选自动提升为生产版。普通地图、规则和进度使用独立公开数据根，但本版第四幕旅行默认路径仍与旧版共用，尚未满足完整隔离；规则配置变化后的旧商旅恢复也有已知缺口。重新安装、升级或切换交付前请导出自有地图；这些实现问题需要另发修复版，文档映射不会改变旧包。

## 已知问题与验收边界

本版仍保留GitHub预发布标记。定版名称不代替功能验收或经济平衡验收。macOS是Universal、ad-hoc签名且未公证，Intel/Windows/Android没有实机验收。配置骰面尚未完整接入运行时；当前仍为1–5加事件面，详见[RULES_CONFIGURATION.md](RULES_CONFIGURATION.md#当前掷骰与事件边界)。

定版审查已复现的实现与交付缺口如下，既有安装包尚未修复：

- 第四幕默认旅行本仍与旧版共用目录，普通公开数据根的隔离没有覆盖这条路径。
- 商旅存档未绑定开局自有规则。合成QA规则A牌价19保存，切换同ID规则B后恢复变29；换牌ID或删配置也可能报告恢复成功。不要在进行中的旧局间切换规则后默认能正确续玩。
- 配置骰面/事件开关未完全接入，空事件牌堆可使AI停止；部分负数事件输入被接受并造成库存与货仓不一致。多项起始物资在重领事件中只发第一项。
- 已核验工坊安装包的25个内置城市模型缺少资源库预览/复用所需的原始GLB字节；导入场景可渲染不表示原始字节检查与绑定可以工作。
- 未配置/未连通草稿中的合法城市模型可预览，却可能被整图正式校验阻止应用；r4有候选修复，但尚未GUI验收并并入生产。
- Android默认棋子的原始GLB字节预检、双应用入口区分和独立APK许可摘要存在交付缺口；没有据此宣称整个Android无法启动。
- 四段`assets/traveler/intro/*_intro.ogv`保留非静音Vorbis音轨，正常播放可能出声。仅清理散装音频不等于片头无声。最终混音的来源/许可仍需独立补证，非静音本身不证明侵权，一般视觉制作的许可也不自动覆盖未知音轨。

制作记录显示片头混音包含自主合成和游戏环境声/录制输入；这些记录帮助定位上游，尚不能确认所有输入的公开许可，也未建立与四个最终混音的完整权利链。保留风险记录，不据此删改既有视频或重新打包。

现有29项回归覆盖配置门禁、局部开局/交易与草稿存读；没有验证完整随机对局、上述规则切换恢复、三端实机或全部编辑功能。问题优先级和后续最小修复依据独立review最终证据确定；本次只统一文档与入口，不改经济算法或包。

版本、源码与包一致性的依据是冻结tag、包内构建记录和SHA256，而不是文件的显示名称。
