-- chainsaw.PlayerBaseContext 上的布尔状态条件。
--
-- 加一个新的:在下面这张表里加一行(id + 方法名),再去 Localization.lua 补 cond_<id> 文案。
-- id 一旦发布就**不要改**——它是写进用户配置文件里的 key。
-- 表的顺序 = 规则面板下拉框的顺序,所以按"战斗 → 姿态 → 环境 → 受伤"分块排。
--
-- 这批是在游戏里用「条件判断」面板逐条实测挑出来的(2026-08-23,里昂)。
-- **方法名和它的实际语义经常不是一回事**,踩到的几个记在 AGENTS.md「实测出来的语义坑」,
-- 文案是按实测语义写的、不是按方法名直译 —— 改文案前先去读那一节,别改回字面意思:
--   * IsAiming  瞄准中**还在动**才为真(人物移动或视角移动都算),光进瞄准站着不动会灭
--   * IsWheel   实测是站定举枪/举刀,跟船舵没关系(船是 IsBoat)
--   * IsCombating 只有近战(刀)攻击才亮,不是泛指交战
--   * IsShooting 真打出子弹才亮;IsPullTrigger 是按了射击键就亮(空枪也算);
--     **空枪击发本身有专门的一条 IsShootDryFire**,别再用 PullTrigger AND not Shooting 去凑
--     —— 正常开枪时"按下"到"出弹"之间也会满足那个组合
--   * IsHolding 举枪/举刀的**完整**状态(2026-11-05 用闩锁探针实测,手枪/霰弹枪/刀):
--     IsAiming 与 IsWheel 亮的帧它**全亮**(漏 0),另外还补上两者之间的空档(起手、停步、
--     放下的过渡帧,约占举枪总帧数的 1/3)。空格举刀也亮。IsReticleDisp、State.Hold
--     与它逐帧一致,不重复收。要"举着武器"就用它;IsAiming/IsWheel 留给只要移动/只要站定的场合
--   * IsPumpAction 名字像泵动霰弹枪上膛,实测是**栓狙拉栓**(2026-08-25;其他武器未测)
--   * IsDamaging 被普通攻击命中就算(零伤害也算),但被控/特写类攻击掉血时不亮
--
-- **这里面有一半是瞬时的**(开火中、扣扳机、空枪击发、拉栓上膛、招架、处决系列、受击、
-- 上半身受击、落地、快速转身、闪避),单独用几乎看不见 —— 配规则上的
-- 「条件结束后保持 N 秒」才好用。实测的单次最长连亮:空枪击发 29 帧、拉栓上膛 50 帧
-- (约 0.5s / 0.8s @60fps),都属于"够长到能看见一下、但短到必须配保持"。
--
-- 枪械那一批同期测的(2026-08-25,探针见 tools/re4/attic/GunProbe.lua.txt):
-- IsWaitingGenerateShell(等待生成弹壳)和 IsShootEnable(瞄准状态可射击)语义都对得上,
-- 但**没实装** —— 前者是内部时序、后者亮的时间太长(4012/6988 帧)没有区分度;
-- IsGunWallHit(枪口顶墙)语义方向没错,只是那次采样里没抓到它亮;
-- IsExReload 和 RequestPumpAction 整段采样都没见亮。
--
-- 没收的候选:IsSprint / IsAttackGuarded / IsInAttackSign / IsRetreat /
-- IsLightArea / IsLightOn / IsDoorPass / IsInsideElevator / IsInsideSuspensionBridge /
-- IsInFreezeDamage / IsJacked / IsHPChanged / checkDyingMode /
-- InSafeRoom / IsGround(它反过来:**几乎恒为真**,没有区分度)——
-- **测的时候没见它们亮,但这只是"很难触发",不是"不会亮"**
-- (吊桥、电梯、冰属性敌人这些场景根本没走到)。完整候选清单和每一条的实测结论在
-- AGENTS.md「条件 backlog」,现成的探测代码在 tools/re4/attic/ —— 想再测就从那里捡回来。

-- `in_safe_room` 之前实装过、现在退出列表:v0.2 起就有这个 id,老配置里可能还引用着它。
-- **id 保留、不要拿去指别的东西** —— 引用它的旧规则会因为找不到 def 而恒不命中
-- (`eval_condition` 找不到 def 直接返回 false),规则列表里显示为原始 id 字符串,
-- 不会崩、也不会误判成命中。想恢复就把下面那行注释放回去。

local BOOL_CONDITIONS = {
    -- 战斗
    { id = "is_battle",           method = "get_IsBattle"          },
    { id = "is_aiming",           method = "get_IsAiming"          },
    { id = "is_wheel",            method = "get_IsWheel"           },
    { id = "is_holding",          method = "get_IsHolding"         },
    -- 举枪的两个细分阶段(2026-11-07 加,用户要求;亮的时机还没实测):
    { id = "is_hold_start",       method = "get_IsHoldStart"       },  -- 举枪起手(还没稳定举着)
    { id = "is_hold_idle",        method = "get_IsHoldIdle"        },  -- 举枪站定不动
    { id = "is_combating",        method = "get_IsCombating"       },
    { id = "is_shooting",         method = "get_IsShooting"        },
    { id = "is_pull_trigger",     method = "get_IsPullTrigger"     },
    { id = "is_shoot_dry_fire",   method = "get_IsShootDryFire"    },
    { id = "is_pump_action",      method = "get_IsPumpAction"      },
    { id = "is_throwing",         method = "get_IsThrowing"        },
    { id = "is_reloading",        method = "get_IsReloading"       },
    { id = "is_weapon_changing",  method = "get_IsWeaponChanging"  },
    { id = "is_parry",            method = "get_IsParry"           },
    { id = "is_big_parry",        method = "get_IsBigParry"        },
    { id = "is_fatal_kick",       method = "get_IsFatalKick"       },
    { id = "is_fatal_round_kick", method = "get_IsFatalRoundKick"  },
    { id = "is_fatal_kill",       method = "get_IsFatalKill"       },
    { id = "is_dodging",          method = "get_IsDodging"         },
    { id = "is_box_break",        method = "get_IsBoxBreak"        },  -- 砸箱子(2026-11-07 加,未实测)
    { id = "is_knife_hold_without_knife", method = "get_IsKnifeHoldWithoutKnife" },  -- 没刀时的举刀动作(同上)

    -- 姿态
    { id = "is_crouch",           method = "get_IsCrouch"          },
    { id = "is_walk",             method = "get_IsWalk"            },
    { id = "is_run",              method = "get_IsRun"             },
    -- 奔跑的三个细分阶段(2026-11-07 加;实测跑动中 IsRunLoop 亮,另外两个未实测)
    { id = "is_run_start",        method = "get_IsRunStart"        },  -- 起跑
    { id = "is_run_loop",         method = "get_IsRunLoop"         },  -- 持续奔跑
    { id = "is_run_turn",         method = "get_IsRunTurn"         },  -- 奔跑中转向
    { id = "is_idle",             method = "get_IsIdle"            },  -- 站立待机(未实测)
    { id = "is_quick_turn",       method = "get_IsQuickTurn"       },
    { id = "is_jumping",          method = "get_IsJumping"         },
    { id = "is_falling",          method = "get_IsFalling"         },
    { id = "is_landing",          method = "get_IsLanding"         },
    { id = "is_ladder",           method = "get_IsLadder"          },
    { id = "is_hook_shot",        method = "get_IsHookShot"        },
    { id = "is_boat",             method = "get_IsBoat"            },

    -- 姿态里只有 State 标志位才有的几个(2026-11-07 加,**还没逐个实测什么时候亮**):
    -- state = PlayerDefine.State 的枚举名,按位测 get_State()
    { id = "is_slip_through",     state = "SlipThrough"            },  -- 钻过缝隙
    { id = "is_parent_gimmick",   state = "ParentGimmick"          },  -- 附着在机关上
    { id = "is_crouch_switching", state = "CrouchSwitching"        },  -- 蹲下/站起过程中(瞬时)

    -- 环境 / 剧情(2026-11-07 加,平时读到全是 false,亮的时机还没实测)
    -- in_safe_room 实测很难亮,见上面的注释
    -- { id = "in_safe_room",        method = "get_InSafeRoom"        },
    { id = "is_talk_acting",      method = "get_IsTalkActing"      },  -- 对话动作中
    { id = "is_wireless_call",    method = "get_IsWirelessCall"    },  -- 无线电通话中
    { id = "is_event_locked",     method = "get_IsEventLocked"     },  -- 事件锁定
    { id = "is_restriction_all",  method = "get_IsRestrictionAll"  },  -- 完全不受玩家控制
    { id = "is_body_draw_off",    state = "BodyDrawOff"            },  -- 身体不绘制

    -- 受伤
    { id = "is_damaging",         method = "get_IsDamaging"        },
    { id = "is_upper_body_damage", method = "get_IsUpperBodyDamage" },
    { id = "is_burning",          method = "get_IsInBurnDamage",   extra = "burn_effect" },
    -- 被束缚:2026-11-07 实测,被敌人抓住时(暂停中读)IsInGrappleDamage 与 isGrappled() 都为真,
    -- 挣脱后都变假;同一时刻 State 里没有 Jacked 位(只在 StateOld 里)、IsJacked 为假,所以不用那两个。
    -- 2026-08-23 那次探针在"擒抱/特写类攻击"里没见它亮 —— 可能是不同的抓取类型,未逐类验证
    { id = "is_grappled",         method = "get_IsInGrappleDamage" },
    -- 被抓 / 刚挣脱:State 或 StateOld 里有 Jacked 位。2026-11-07 实测:被抓期间和挣脱反击期间
    -- State 里都没有 Jacked、IsJacked 为假,只有 StateOld 留着这一位(反击时无敌为真、闪避为假,
    -- 用户的"闪避类无敌隐身"规则靠它排除这一段)。StateOld 在反击结束后残留多久还没测。
    { id = "is_jacked",           state = "Jacked", with_old = true },
    -- 捂伤口:PlayerBodyUpdater.get_NextAddArmIndex() 为 4 或 5(叠加手臂动作层的编号,-1 = 没有叠加)。
    -- 这一层不是捂伤口专用:2026-11-07 第二轮探针(满血切武器 + 实战)看到 0 = 切武器起手那一帧、
    -- 2 = 某些武器的单手待机姿势(满血拿着能保持几分钟),所以早先的 ">= 0" 会把持枪误判成捂伤口。
    -- 挨打后出现的只有 4(那次没见 5),切武器时清回 -1。
    -- 但用户随后又在没捂伤口时读到 4,说明 4 也不专属于捂伤口 —— 暂时隐藏(hidden → legacy:
    -- 下拉框和总览里不列,已经在用它的配置照常求值),等找到真正的信号再放出来。
    -- 2026-11-07 用 Lua 探针实测(血量正常时对比 + 一段 3~5 次捂伤口的时间线):挨打后变成 4 或 5,
    -- 一直保持到人物放下手(4~20 秒),放下后回到 -1;和血量等级无关(HP 正常也会捂)。
    -- 挨打那一两帧会闪一下 -1,配「保持」就平了。4 / 5 的区别(哪只手 / 哪种捂法)还没分清。
    -- 之前试过的 BodyUpdater._IsOldDanger 是 MCP 读错偏移得出的假阳性(Lua 读是 false),别再用;
    -- ActingOnceType 当时也变过,实测是 Surprised_Explosion(被爆炸吓到),无关。
    { id = "is_wounded",          body_call = "get_NextAddArmIndex", values = { [4] = true, [5] = true }, hidden = true },
    { id = "is_invincible",       method = "get_IsInvincible"      },
}

-- 补充判断:方法返回 false 时再看这些,任一成立就算 true。
--   burn_effect:被普通火焰攻击点燃时 get_IsInBurnDamage 不置位(实测 2026-11-06,攻击类型 EmFlameBlow,
--   State 里也没有燃烧位),但 BodyUpdater 的 _CurrentBurnEffectID 是 Start(0) 及以上、燃烧循环特效在播;
--   火灭后回到 Invalid(-1)。字段在 chainsaw.PlayerBodyUpdater 上(各角色的 BodyUpdater 都继承它)
local EXTRA = {
    burn_effect = function(context)
        local ok, id = pcall(function()
            local body = context:call("get_BodyUpdater")
            return body and body:get_field("_CurrentBurnEffectID")
        end)
        return ok and type(id) == "number" and id >= 0
    end,
}

-- State 标志位:枚举值反射一次缓存;get_State() 是 64 位整数,按位与判断
local state_bits = {}
local function state_bit(name)
    if state_bits[name] == nil then
        local bit = false
        local td = sdk.find_type_definition("chainsaw.PlayerDefine.State")
        local f = td and td:get_field(name)
        local ok, v = pcall(function() return f and f:get_data(nil) end)
        if ok and type(v) == "number" then bit = math.tointeger(v) or false end
        state_bits[name] = bit
    end
    return state_bits[name]
end
local function read_state(context, name, with_old)
    local bit = state_bit(name)
    if not bit then return nil end
    local ok, st = pcall(function() return context:call("get_State") end)
    st = ok and type(st) == "number" and math.tointeger(st) or nil
    if not st then return nil end
    if (st & bit) ~= 0 then return true end
    if with_old then
        local ok_o, so = pcall(function() return context:call("get_StateOld") end)
        so = ok_o and type(so) == "number" and math.tointeger(so) or nil
        if so then return (so & bit) ~= 0 end
    end
    return false
end

local defs = {}
for _, entry in ipairs(BOOL_CONDITIONS) do
    table.insert(defs, {
        id = entry.id,
        kind = "bool",
        label_key = "cond_" .. entry.id,
        legacy = entry.hidden or nil,
        get = function(context)
            if not context then return nil end
            if entry.state then return read_state(context, entry.state, entry.with_old) end
            if entry.body_call then
                local ok_b, v = pcall(function()
                    local body = context:call("get_BodyUpdater")
                    return body and body:call(entry.body_call)
                end)
                if ok_b and type(v) == "number" then return entry.values[math.tointeger(v)] == true end
                return nil
            end
            local ok, v = pcall(function() return context:call(entry.method) end)
            if ok and type(v) == "boolean" then
                if not v and entry.extra and EXTRA[entry.extra](context) then return true end
                return v
            end
            return nil
        end,
    })
end

return defs
