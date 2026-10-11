-- Auto-fulfill noble production (Make) mandates. Export bans are left alone.
--@enable = true
--@module = true

local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'malphars_mandates'

enabled = enabled or false

function isEnabled()
    return enabled
end

local function fulfill_production()
    if not enabled or not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
        return
    end
    local md = df.global.world.mandates.all
    if not md then return end
    local done = 0
    for i = #md - 1, 0, -1 do
        local m = md[i]
        if m and m.mode == df.mandate_type.Make then
            if m.amount_remaining and m.amount_remaining > 0 then
                m.amount_remaining = 0
                done = done + 1
            end
            -- Clear finished Make mandates so the nobles screen stays empty.
            if not m.amount_remaining or m.amount_remaining <= 0 then
                md:erase(i)
                m:delete()
            end
        end
    end
    if done > 0 then
        print(("Malphar's Mod: fulfilled %d production mandate(s)."):format(done))
    end
end

local function do_enable()
    enabled = true
    repeatutil.scheduleEvery(GLOBAL_KEY, 200, 'ticks', fulfill_production)
    fulfill_production()
    print("Malphar's Mod: production mandates complete automatically.")
end

local function do_disable()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY)
    print("Malphar's Mod: production-mandate helper is off.")
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        repeatutil.cancel(GLOBAL_KEY)
        return
    end
    if sc ~= SC_MAP_LOADED or not dfhack.world.isFortressMode() then
        return
    end
    do_enable()
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then
        if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
            do_enable()
        else
            enabled = true
        end
    else
        do_disable()
    end
    return
end

if dfhack_flags.module then
    return
end

if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
    do_enable()
end
