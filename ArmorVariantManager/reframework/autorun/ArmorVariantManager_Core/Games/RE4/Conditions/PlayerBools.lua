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
-- IsInFreezeDamage / IsInGrappleDamage / IsJacked / IsHPChanged / checkDyingMode /
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

    -- 姿态
    { id = "is_crouch",           method = "get_IsCrouch"          },
    { id = "is_walk",             method = "get_IsWalk"            },
    { id = "is_run",              method = "get_IsRun"             },
    { id = "is_quick_turn",       method = "get_IsQuickTurn"       },
    { id = "is_jumping",          method = "get_IsJumping"         },
    { id = "is_falling",          method = "get_IsFalling"         },
    { id = "is_landing",          method = "get_IsLanding"         },
    { id = "is_ladder",           method = "get_IsLadder"          },
    { id = "is_hook_shot",        method = "get_IsHookShot"        },
    { id = "is_boat",             method = "get_IsBoat"            },

    -- 环境:暂时没有(in_safe_room 实测很难亮,见上面的注释)
    -- { id = "in_safe_room",        method = "get_InSafeRoom"        },

    -- 受伤
    { id = "is_damaging",         method = "get_IsDamaging"        },
    { id = "is_upper_body_damage", method = "get_IsUpperBodyDamage" },
    { id = "is_burning",          method = "get_IsInBurnDamage"    },
    { id = "is_invincible",       method = "get_IsInvincible"      },
}

local defs = {}
for _, entry in ipairs(BOOL_CONDITIONS) do
    table.insert(defs, {
        id = entry.id,
        kind = "bool",
        label_key = "cond_" .. entry.id,
        get = function(context)
            if not context then return nil end
            local ok, v = pcall(function() return context:call(entry.method) end)
            if ok and type(v) == "boolean" then return v end
            return nil
        end,
    })
end

return defs
