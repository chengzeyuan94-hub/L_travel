# 配置玩法规则

## 已提供的功能数值配置

[下载功能数值规则JSON](https://github.com/chengzeyuan94-hub/L_travel/releases/download/v0.2.4-public.1/LTravel-functional-rules-v1.json)，适用于现有0.2.4-public.1包。包含本项目r2功能基线的80贸易牌数值、陆海各18事件机器效果、15货物供应和16城起始物资；事件文字重新撰写。使用“配置玩法规则 → 导入已确认的规则文件”，保存成功后重开程序并新建对局。地图已随包提供，不需要另外导入。见[详细步骤](rules/IMPORT-RULES.md)与[实际验证边界](rules/RULES-VALIDATION.json)。

这是2026-10-19按项目维护者明确要求新增的独立配置文件；既有安装包、引擎、tag和原创v2算法未改。该文件不含原卡图像/原文，且不代表获得原作者授权或把第三方数据纳入本仓库代码/素材许可。以下说明仍适用于自行编辑其他配置。

## 当前掷骰与事件边界

v0.2.4-public.1的`DiceSystem.roll()`仍固定从1–5及EVENT面中掷骰，`is_valid_face()`也只接受1–5/EVENT。配置入口虽然读取并校验`dice_faces`字段，但运行掷骰没有使用它；因此改该字段不能改变骰子，`events_enabled:false`也不会自动消除事件面。若该面被掷出但对应牌堆为空，事件会被阻止。现版应提供与交通工具匹配的LAND/SEA自有事件，仍须验证整局运行。

这是现有配置接口的已知不一致。本次提供的独立配置使用固定1–5+EVENT和完整陆海事件，与当前引擎一致；没有修改骰子算法。若要支持无事件骰或其他面数，需要另外确认并修改核心代码、验证完整回合。

已发布安装包中的贸易牌数值、事件、商品供应量和城市起始物资仍为空；上方独立JSON可补入功能数据，原事件文字不提供。启动后可以编辑、保存、重开地图，直接进入四幕旅行；正式商旅开局及工坊试玩需要先配置。界面右下角选择「配置玩法规则」，导入已确认的JSON文件；也可用高级编辑粘贴JSON。未确认/缺项配置不会写入，错误配置不会覆盖原配置。

需要生成或修改另一套规则时，Agent应根据使用者已确认的经济、供应、起始物资、骰子、事件效果/自有文字、牌堆长度、生成参数和种子执行；缺失的决定再询问，已有授权不重复确认。不得擅自复制原卡图片/原文、推断所谓官方公式，或把tests里的QA参数当默认玩法。仓库已提供的功能数值配置可直接按上述步骤导入。

`PublicRules.template()` 是空配置骨架（schema `lshu.rules.config.v1`），`PublicRules.install(json_text)` 校验并原子保存到用户数据目录的 `rules-config.json`。所有商品/城市ID对应基础地理数据；每座城市需绑定非空贸易牌堆，卡牌ID需唯一，每张卡4项。条目字段为 `resource_kind`（GOOD/SILVER）、`resource_id`、正整数 `quantity`；GOOD必须存在，SILVER使用silver。城市输入为 `city_id` 与 `starting_grant.entries`。`ruleset`包含 `warehouse_capacity`、`open_trade_route_reward`、`direct_sale_rate`、按2/3/4人计的 `silver_supply_by_player_count` 和 `dice_faces`；本实现的货仓UI/校验支持容量4。骰面支持正整数与EVENT，后者需启用事件。基础地理的交通资格仍按图上城市与路线约束。

本实现保留现有机制：银库拿空后的终局、按完整比例交易、玩家选择丢货、事件弃牌洗回、白银减半向上取整、单件半货无损，以及完整起始物资发放。这是当前引擎支持范围，配置文件不得暗示它支持尚未实现的另一种机制。要改这些机制必须先确认范围并改代码/测试，不能仅改标签或经济数值。

贸易生成：`PublicRules.generate_trade(request, params)`调用已有v2；request需 `confirmed_by_owner:true`、商品/产地/距离/商品映射字典和城市拓扑数组。参数包括版本、5组 `local_batches`、`silver_cap`、`price_base`、`distance_step`、`silk_count`、`partner_count`、`foreign_max`、`weight_scale`、`assignment_relaxation_budget`。接口不自动填入老参数。生成的是新增城市牌堆；完整基础牌堆也需使用者提供自有配置。

事件生成：`PublicRules.generate_events(recipes, seed)`仅处理自有模板和显式变量。每条需唯一 `id`、LAND/SEA `deck_type`、自有 `template` 和受支持的 `effects`；`variables`的数组候选由固定种子选择。效果操作码见 `GameData.KNOWN_EVENT_OPS`，不得猜测未定义操作。关闭事件需明确 `events_enabled:false`；没有内置原事件文字回退。

保存配置后重新打开工坊，使现有地图重新按规则校验。不要将规则配置视为经济平衡认证；正式开局、交易/事件、AI和终局仍需使用者对其玩法验证。
