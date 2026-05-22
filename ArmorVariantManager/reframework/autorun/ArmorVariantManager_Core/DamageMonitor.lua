local DamageMonitor = {}
local last_hp = {}

function DamageMonitor.check_damage(char_addr, cur_hp)
    if not cur_hp then return false end
    local prev = last_hp[char_addr]
    local took_damage = false
    
    if prev and (prev - cur_hp) > 0.1 then
        took_damage = true
    end
    
    last_hp[char_addr] = cur_hp
    return took_damage
end

return DamageMonitor
