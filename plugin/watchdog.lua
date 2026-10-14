-- GPL-3.0-or-later. Per-mpv-instance lease; survives IINA JS plugin unload.
local utils = require 'mp.utils'
local paths, last = {}, nil
local hwdecBefore = nil
local function cleanup()
    local current = mp.get_property_native('glsl-shaders', {})
    local next = {}
    for _, p in ipairs(current) do if not paths[p] then next[#next+1]=p end end
    if #next ~= #current then mp.set_property_native('glsl-shaders', next) end
    for _, f in ipairs(mp.get_property_native('vf', {})) do
        if f.label == 'iive-motion' then mp.commandv('vf','remove','@iive-motion') end
    end
    local decoder = mp.get_property_native('hwdec')
    local ours = decoder == 'no' or (type(decoder)=='table' and #decoder==1 and decoder[1]=='no')
    if hwdecBefore and ours then mp.set_property_native('hwdec', hwdecBefore) end
    hwdecBefore = nil; paths = {}; last = nil
end
mp.register_script_message('iive-lease', function(payload)
    local data = utils.parse_json(payload)
    if type(data) ~= 'table' or type(data.paths) ~= 'table' then return end
    for _, p in ipairs(data.paths) do
        if type(p)=='string' and p:find('/iive%-') then paths[p]=true end
    end
    hwdecBefore = (type(data.hwdecBefore)=='string' or type(data.hwdecBefore)=='table') and data.hwdecBefore or nil
    last = mp.get_time()
    mp.set_property_native('user-data/iive-watchdog', true)
end)
mp.register_script_message('iive-release', cleanup)
mp.add_periodic_timer(1, function() if last and mp.get_time()-last>5 then cleanup() end end)
mp.register_event('shutdown', cleanup)
