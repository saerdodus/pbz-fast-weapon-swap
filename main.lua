--[[
    pbz-fast-weapon-swap — 影之刃零「切换武器快速冷却」独立 UE4SS 模组
    =====================================================================
    原理（参考修改器内嵌的 Cheat Engine 脚本）：

      aobscanmodule(aobweaponcd,PBZ.exe,F3 * 0F 5C * F3 0F 58 74 3E 34 F3 * 0F 5F)
      newmem:
        cmp [weapon_cd],1
        jne code
        mov [rsi+rdi+34],(float)0.1     ; 把每把武器配置里的冷却值改成 0.1
      code:
        addss xmm6,[rsi+rdi+34]
        jmp return

      修改器用代码补丁在「切换武器冷却计算」里把每把武器的冷却字段硬改成 0.1 秒。

    本模组不碰 EXE、不改内存指令，而是走 UE 反射层的公开入口：
      - /Script/SGameCombatSystem.CharacterWeaponsComponent:StartChangeWeaponCooldown
        切换武器开始冷却时触发；
      - ...:GetCurrentChangeWeaponCooldown
        读取当前冷却剩余时间（HUD/逻辑查询时触发）；
      - ...:ResetChangeWeaponCooldowns
        把切换武器冷却清零（游戏自己的函数，无参数）。
    在冷却开始时按配置延迟清零，或在查询到剩余冷却超过配置值时清零，
    从而把「切换武器冷却」控制在 config.txt 里设置的秒数。
]]

local MOD_NAME = "pbz-fast-weapon-swap"
local CLASS_PATH = "/Script/SGameCombatSystem.CharacterWeaponsComponent"
local CLASS_SHORT = "CharacterWeaponsComponent"

local DEFAULTS = {
    enabled = true,
    -- 切换武器后多久把冷却清掉（= 实际冷却时间）。
    -- 0.9 秒是安全值：等切换动画/图标更新完成后再清冷却，不会打断 HUD。
    cooldown_seconds = 0.9,
    poll_interval_ms = 250,
    log = true,
    debug = false,
}

-- ---------------------------------------------------------------- 路径/日志
local function script_dir()
    local source = (debug.getinfo(1, "S") or {}).source or ""
    source = source:gsub("^@", ""):gsub("/", "\\")
    return source:match("^(.*)\\[^\\]*$") or "."
end
local SCRIPT_DIR = script_dir()
local MOD_DIR = SCRIPT_DIR
if MOD_DIR:sub(-8) == "\\Scripts" then MOD_DIR = MOD_DIR:sub(1, -9) end
local CONFIG_PATH = MOD_DIR .. "\\config.txt"
local LOG_PATH = MOD_DIR .. "\\weapon_swap_log.txt"

local log_enabled = true
local log_file = nil
local function log_open()
    if not log_enabled then return end
    if log_file then pcall(function() log_file:close() end) end
    local ok, handle = pcall(io.open, LOG_PATH, "w")
    log_file = ok and handle or nil
end
local function log(msg)
    if not log_enabled then return end
    local okDate, stamp = pcall(os.date, "%H:%M:%S")
    if not okDate or not stamp then stamp = tostring(os.time and os.time() or 0) end
    local text = string.format("[%s] %s", tostring(stamp), tostring(msg))
    print("[" .. MOD_NAME .. "] " .. tostring(msg))
    if log_file then
        pcall(function()
            log_file:write(text .. "\r\n")
            log_file:flush()
        end)
    end
end

-- ---------------------------------------------------------------- 小工具
local function isValid(value)
    if value == nil then return false end
    local ok, result = pcall(function() return value:IsValid() end)
    return ok and result == true
end
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function unwrap(value)
    if value == nil or type(value) ~= "userdata" then return value end
    local ok, inner = pcall(function() return value:get() end)
    if ok and inner ~= nil and inner ~= value then return inner end
    ok, inner = pcall(function() return value:Get() end)
    if ok and inner ~= nil and inner ~= value then return inner end
    return value
end
local function as_number(value)
    local v = unwrap(value)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) end
    return nil
end
local function trim(text)
    return (text or ""):match("^%s*(.-)%s*$") or ""
end

-- ---------------------------------------------------------------- 配置
local config = {}

local function parse_value(raw)
    raw = trim(raw)
    if raw == "" then return nil end
    local lower = raw:lower()
    if lower == "true" then return true end
    if lower == "false" then return false end
    local number = tonumber(raw)
    if number then return number end
    return raw
end

local function write_default_config()
    local ok, handle = pcall(io.open, CONFIG_PATH, "w")
    if not ok or not handle then return end
    pcall(function()
        handle:write([[
# ============================================================
#  pbz-fast-weapon-swap 配置文件（UTF-8）
#  改完保存后，游戏内按 Ctrl+F6 重新读取，无需重启游戏
# ============================================================

# 是否启用
enabled = true

# 切换武器后多久把冷却清掉（秒），也就是实际冷却时间：
#   0.9  = 推荐安全值：等 HUD 切换动画播完再清冷却
#   1.2  = 更保守
#   0.5  = 更快，但个别机器上可能打断 HUD 图标切换动画
# 注意：不要低于 0.5；设成 0.1 可能导致“武器切了但图标不换位置”
cooldown_seconds = 0.9

# 轮询间隔（毫秒）：仅用于发现玩家武器组件，不参与清冷却
poll_interval_ms = 250

# 写日志到 weapon_swap_log.txt
log = true

# 详细日志（排查问题时开）
debug = false
]])
        handle:close()
    end)
end

local function load_config()
    local result = {}
    for key, value in pairs(DEFAULTS) do result[key] = value end
    local exists = false
    local ok, handle = pcall(io.open, CONFIG_PATH, "r")
    if ok and handle then
        exists = true
        local content = handle:read("*a") or ""
        handle:close()
        local warnings = {}
        for line in content:gmatch("[^\r\n]+") do
            local body = line
            local hash = body:find("#", 1, true)
            if hash then body = body:sub(1, hash - 1) end
            local semi = body:find(";", 1, true)
            if semi then body = body:sub(1, semi - 1) end
            body = trim(body)
            if body ~= "" then
                local key, value = body:match("^([%w_]+)%s*=%s*(.-)$")
                if key then
                    key = key:lower()
                    if DEFAULTS[key] == nil then
                        warnings[#warnings + 1] = "忽略未知配置项: " .. key
                    else
                        local parsed = parse_value(value)
                        if parsed == nil then
                            warnings[#warnings + 1] = "配置项为空，使用默认值: " .. key
                        else
                            result[key] = parsed
                        end
                    end
                else
                    warnings[#warnings + 1] = "无法解析的行: " .. body
                end
            end
        end
        result._warnings = warnings
    end
    if not exists then
        write_default_config()
        result._created = true
    end
    result.enabled = result.enabled == true
    result.log = result.log ~= false
    result.debug = result.debug == true
    if not finite(result.cooldown_seconds) then result.cooldown_seconds = DEFAULTS.cooldown_seconds end
    result.cooldown_seconds = math.max(0.1, math.min(10, result.cooldown_seconds))
    if not finite(result.poll_interval_ms) or result.poll_interval_ms < 50 then
        result.poll_interval_ms = DEFAULTS.poll_interval_ms
    end
    result.poll_interval_ms = math.min(2000, math.floor(result.poll_interval_ms))
    return result
end

-- ---------------------------------------------------------------- 玩家/组件
local okHelpers, UEHelpers = pcall(require, "UEHelpers")
if not okHelpers or type(UEHelpers) ~= "table" then UEHelpers = nil end

local cachedPlayer, playerRefreshAt = nil, 0
local function find_player_fallback()
    local list = FindAllOf("PlayerController") or FindAllOf("Controller")
    if list then
        for _, controller in ipairs(list) do
            if isValid(controller) then
                local localPlayer = false
                pcall(function()
                    if controller.IsLocalPlayerController then
                        localPlayer = controller:IsLocalPlayerController() == true
                    elseif controller.IsPlayerController then
                        localPlayer = controller:IsPlayerController() == true
                    end
                end)
                if localPlayer then
                    local pawn = nil
                    pcall(function() pawn = controller.Pawn end)
                    if isValid(pawn) then return pawn end
                end
            end
        end
    end
    return nil
end
local function player()
    local now = os.time()
    if isValid(cachedPlayer) and now < playerRefreshAt then return cachedPlayer end
    cachedPlayer = nil
    if UEHelpers and UEHelpers.GetPlayer then
        local ok, value = pcall(UEHelpers.GetPlayer)
        if ok and isValid(value) then cachedPlayer = value end
    end
    if not isValid(cachedPlayer) then cachedPlayer = find_player_fallback() end
    playerRefreshAt = now + 2
    return cachedPlayer
end

local component = nil
local componentLogged = false

local function belongs_to_player(comp, p)
    if not isValid(comp) then return false end
    local owner = nil
    pcall(function() owner = comp:GetOuter() end)
    if not isValid(owner) then return false end
    if isValid(p) and owner:GetAddress() == p:GetAddress() then return true end
    local ok, controlled = pcall(function() return owner:IsPlayerControlled() end)
    return ok and controlled == true
end

local function find_component()
    local p = player()
    local names = { CLASS_SHORT, CLASS_PATH }
    for _, name in ipairs(names) do
        local ok, list = pcall(FindAllOf, name)
        if ok and type(list) == "table" and #list > 0 then
            local fallback = nil
            for _, candidate in ipairs(list) do
                if isValid(candidate) then
                    if belongs_to_player(candidate, p) then return candidate end
                    if fallback == nil then fallback = candidate end
                end
            end
            if fallback then return fallback end
        end
    end
    return nil
end

local function refresh_component(force)
    if isValid(component) and not force then return component end
    local found = find_component()
    if isValid(found) then
        component = found
        if not componentLogged then
            componentLogged = true
            local name = "?"
            pcall(function() name = found:GetFullName() end)
            log("找到玩家武器组件: " .. tostring(name))
        end
        return component
    end
    return nil
end

-- ---------------------------------------------------------------- 冷却清零
local resets = 0
local lastResetError = nil

local function reset_cooldown(comp, reason)
    if not isValid(comp) then return false end
    local ok, err = pcall(function() comp:ResetChangeWeaponCooldowns() end)
    if ok then
        resets = resets + 1
        if config.debug then
            log(string.format("已清零切换武器冷却（%s，累计 %d 次）", tostring(reason), resets))
        end
        return true
    end
    if lastResetError ~= tostring(err) then
        lastResetError = tostring(err)
        log("ResetChangeWeaponCooldowns 调用失败: " .. tostring(err))
    end
    return false
end

local function schedule_reset(comp, reason)
    if not isValid(comp) then return end
    local delay = math.floor((config.cooldown_seconds or 0.9) * 1000 + 0.5)
    if delay < 100 then delay = 100 end
    ExecuteInGameThreadWithDelay(delay, function()
        pcall(reset_cooldown, comp, reason .. "+" .. tostring(delay) .. "ms")
        return false
    end)
end

-- ---------------------------------------------------------------- 挂钩
local hooksReady = false
local hookErrors = {}
local startSeen = false
local getterSeen = false

local function unwrap_param(param)
    return unwrap(param)
end

local function on_start(selfParam)
    local selfObj = unwrap_param(selfParam)
    if not isValid(selfObj) then return end
    component = selfObj
    if not config.enabled then return end
    if not startSeen then
        startSeen = true
        log("检测到切换武器冷却开始（StartChangeWeaponCooldown Hook 已生效）")
    end
    schedule_reset(selfObj, "StartChangeWeaponCooldown")
end

local function on_get_cooldown(selfParam, returnParam)
    local selfObj = unwrap_param(selfParam)
    if not isValid(selfObj) then return end
    component = selfObj
    if not config.enabled then return end
    local remaining = nil
    if returnParam ~= nil then
        remaining = as_number(returnParam)
    end
    if not getterSeen then
        getterSeen = true
        if config.debug then
            log("首次读取切换武器冷却，剩余 = " .. tostring(remaining))
        end
    end
    -- 注意：这里绝对不要在冷却查询过程中清零冷却。
    -- HUD 的武器图标切换动画是在切换流程中播放的，过早 Reset 会打断动画，
    -- 导致“切换了武器但图标不换位置”。只在 StartChangeWeaponCooldown 之后
    -- 延迟一次清零（见 schedule_reset），等动画播完再清。
end

local function register_hooks()
    if hooksReady then return true end
    local functions = {
        -- { UFunction 名, 前置回调, 后置回调 }
        { "StartChangeWeaponCooldown", nil, on_start },
        { "GetCurrentChangeWeaponCooldown", nil, on_get_cooldown },
    }
    local allOk = true
    for _, entry in ipairs(functions) do
        local name, preFn, postFn = entry[1], entry[2], entry[3]
        if preFn == nil then preFn = function() end end
        local ok, id1, id2 = pcall(RegisterHook, CLASS_PATH .. ":" .. name, preFn, postFn)
        -- UE4SS 的 RegisterHook 在找不到 UFunction 时不抛错，而是把错误文本
        -- 作为第一个返回值返回；成功时返回两个数字 id。
        if ok and type(id1) == "number" then
            log(string.format("已挂钩 %s (id1=%s id2=%s)", name, tostring(id1), tostring(id2)))
        else
            allOk = false
            local text = tostring(id1)
            if hookErrors[name] ~= text then
                hookErrors[name] = text
                log("挂钩 " .. name .. " 失败（等类加载后会自动重试）: " .. text:sub(1, 200))
            end
        end
    end
    if allOk then
        hooksReady = true
        log("切换武器冷却 Hook 已就绪")
    end
    return allOk
end

-- ---------------------------------------------------------------- 清理/轮询
local function poll()
    if not hooksReady then
        local okClass = false
        local okFind, classObj = pcall(StaticFindObject, CLASS_PATH)
        if okFind and classObj ~= nil then okClass = true end
        if okClass then register_hooks() end
        return
    end
    if not config.enabled then return end
    -- 只做组件发现，不在这里调用任何游戏函数、也不清零冷却。
    -- 轮询里清零会打断切换武器动画（图标不换位置），已移除。
    refresh_component()
end

-- ---------------------------------------------------------------- 热键/热重载
local function reload_config(reason)
    local old = config
    local new = load_config()
    config = new
    log_enabled = config.log ~= false
    if not log_enabled then
        if log_file then pcall(function() log_file:close() end) end
        log_file = nil
    elseif log_file == nil then
        log_open()
    end
    log(string.format("配置已重新加载：%s，目标冷却 %.2f 秒（触发：%s）",
        config.enabled and "开启" or "关闭", config.cooldown_seconds, tostring(reason or "")))
    if type(config._warnings) == "table" then
        for _, warning in ipairs(config._warnings) do log("配置提醒: " .. warning) end
    end
    if old.enabled ~= config.enabled and config.enabled and isValid(component) then
        log("已启用，下一次切换武器生效")
    end
    -- 注意：poll_interval_ms 的修改需要重启游戏才生效（轮询循环在启动时注册）
end

local function toggle_enabled()
    config.enabled = not config.enabled
    if not config.enabled then
        if isValid(component) then reset_cooldown(component, "toggle-off") end
        log("已关闭切换武器快速冷却（当前冷却已清零一次）")
    else
        log("已开启切换武器快速冷却：目标 " .. string.format("%.2f", config.cooldown_seconds) .. " 秒")
    end
end

local function register_hotkeys()
    pcall(function()
        RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, function()
            ExecuteInGameThread(function() reload_config("Ctrl+F6") end)
        end)
        RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, function()
            ExecuteInGameThread(function() toggle_enabled() end)
        end)
    end)
end

-- ---------------------------------------------------------------- 启动
do
    local initial = load_config()
    log_enabled = initial.log ~= false
    log_open()
    config = initial
    log(string.format("%s 已加载：%s，目标冷却 %.2f 秒，轮询 %dms",
        MOD_NAME, config.enabled and "开启" or "关闭", config.cooldown_seconds, config.poll_interval_ms))
    if config._created then log("首次运行：已生成默认配置文件 " .. CONFIG_PATH) end
    if type(config._warnings) == "table" then
        for _, warning in ipairs(config._warnings) do log("配置提醒: " .. warning) end
    end
    register_hotkeys()

    -- 等类加载后注册 Hook（/Script 原生类在游戏模块初始化后才可注册）
    LoopInGameThreadWithDelay(1000, function()
        local ok, err = pcall(function()
            if not hooksReady then
                local okFind, classObj = pcall(StaticFindObject, CLASS_PATH)
                if okFind and classObj ~= nil then
                    register_hooks()
                end
            end
        end)
        if not ok and config.debug then log("Hook 重试错误: " .. tostring(err)) end
        return not hooksReady
    end)

    poll_interval_ms = config.poll_interval_ms
    LoopInGameThreadWithDelay(poll_interval_ms, function()
        local ok, err = pcall(poll)
        if not ok and config.debug then log("轮询错误: " .. tostring(err)) end
        return true
    end)
end
