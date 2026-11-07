# PBZ Fast Weapon Swap — Configurable (UE4SS)

《影之刃零》独立「快速切换武器」模组源码 / Standalone fast weapon-swap mod source for **Phantom Blade Zero**.

- **Nexus Mods**: <https://www.nexusmods.com/phantombladezero/mods/675>
- **游戏版本**: UE 5.7.4 / CL-302256（v1.0 更新后验证）
- **依赖**: [PBZ UE4SS](https://www.nexusmods.com/phantombladezero/mods/13)
- **许可证**: MIT

![cover](https://staticdelivery.nexusmods.com/mods/10614/images/675/675-1794018059-1282055517.jpg)

---

## 功能 / Features

- 切换武器后只等待可配置的冷却时间（默认 **0.9 秒**），远快于原版；
- 通过游戏自身 UE 反射接口实现，**不修改 EXE / 机器码**；
- 切换动画播完才清冷却，**保留右下角武器图标的切换动画**；
- 不写存档、不改武器伤害 / 其它技能冷却；
- 游戏内热键开关与重载配置，日志可查。

## 安装 / Installation

### 从 Nexus 下载（推荐）

<https://www.nexusmods.com/phantombladezero/mods/675> → Files → 下载 `pbz-fast-weapon-swap-v1.1.zip`，
解压到：

```
<游戏目录>\platform\steam\ue4ss\Mods\pbz-fast-weapon-swap\
```

### 从源码安装 / From source

1. 把本仓库的 `main.lua` 放到 `<游戏目录>\platform\steam\ue4ss\Mods\pbz-fast-weapon-swap\Scripts\main.lua`
   （`Scripts` 目录不存在就自己建）；
2. 把 `config.txt` 放到 `<游戏目录>\platform\steam\ue4ss\Mods\pbz-fast-weapon-swap\config.txt`；
3. 新建一个空文件 `enabled.txt` 放在同目录下（用于让 UE4SS 自动启用）；
4. 启动游戏，切换武器测试。日志：`Mods\pbz-fast-weapon-swap\weapon_swap_log.txt`。

## 仓库结构 / Repo layout

```
main.lua      # 模组主体（Lua / UE4SS）
config.txt    # 默认配置
```

## 配置 / Configuration

编辑 `config.txt`，保存后游戏内按 **Ctrl+F6** 重新读取：

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关（游戏内 Ctrl+F5 也可切换） |
| `cooldown_seconds` | `0.9` | 切换后多久清冷却（秒），即实际冷却时间；推荐 `0.9`，可调 `0.5–1.5`。**不要低于 0.5**，太低可能打断 HUD 武器图标切换动画 |
| `poll_interval_ms` | `250` | 仅用于发现玩家武器组件的轮询间隔；修改后需重启游戏生效 |
| `log` | `true` | 是否写 `weapon_swap_log.txt` |
| `debug` | `false` | 详细日志（排查用） |

## 热键 / Hotkeys

| 热键 | 功能 |
| --- | --- |
| **Ctrl+F6** | 重新读取 `config.txt` |
| **Ctrl+F5** | 临时开启 / 关闭模组 |

## 实现原理 / How it works

原修改器用 Cheat Engine 代码补丁直接改「切换武器冷却计算」。本模组不碰 EXE，而是调用游戏暴露的 UE 反射接口：

- `/Script/SGameCombatSystem.CharacterWeaponsComponent:StartChangeWeaponCooldown` — 切换武器开始进入冷却时触发；
- `...:GetCurrentChangeWeaponCooldown` — 读取当前剩余冷却（逻辑 / HUD 查询时触发）；
- `...:ResetChangeWeaponCooldowns` — 游戏自带的「清零切换武器冷却」函数（无参数）。

模组在冷却开始后按 `cooldown_seconds` **延迟一次**清冷却：等 HUD 切换动画播完再清，所以不会出现「武器切了、右下角图标不换位置」的问题；不会在冷却查询或轮询里反复清零。

## 排查 / Troubleshooting

日志：`Mods\pbz-fast-weapon-swap\weapon_swap_log.txt`。正常应包含：

```
已挂钩 StartChangeWeaponCooldown ...
已挂钩 GetCurrentChangeWeaponCooldown ...
切换武器冷却 Hook 已就绪
找到玩家武器组件: ...
```

如果只有 `已加载`、没有 `已挂钩`，说明游戏更新改了类路径，请开 issue 并附日志。

## 兼容与注意 / Compatibility & Notes

- 只影响「切换武器冷却」，不改武器伤害 / 其它技能冷却；
- 模组只会把剩余冷却提前清零，不会延长原版冷却；
- 不写存档；卸载直接删除 `pbz-fast-weapon-swap` 文件夹即可；
- 单人离线使用，联机请勿使用。

## 更新日志 / Changelog

- **v1.1** — 修复「切换武器后右下角武器图标不换位置」：清冷却改为切换后延迟一次（默认 0.9s），移除轮询 / 查询时的反复清零，保留 HUD 切换动画；
- **v1.0** — 首个发布版，基于原修改器机制重写为独立 UE4SS 模组。

## 许可证 / License

[MIT](LICENSE) © 2026 saerdodus

## 致谢 / Credits

- 本模组的代码、文档与封面在 **DeepSeek Harness (AI)** 辅助下完成；发布前已人工验证与测试。
- 《影之刃零》游戏及其资产归 **S-GAME** 所有；本仓库不包含任何游戏资源。
