local obs = obslua
-- The isolated libobs process has no frontend; app callbacks are tested in OBS UI.
obs.obs_frontend_add_event_callback = function() end
obs.obs_frontend_remove_event_callback = function() end
local passed, why = pcall(function()
    dofile('ambient-source-events.lua')
    local load_product = script_load
    load_product()
    script_load = nil
    local settings = obs.obs_data_create()
    local source = obs.obs_source_create_private('lua_ambient_source_events_v1', 'ASE shader smoke', settings)
    assert(source, 'Filter registration failed')
    local props = obs.obs_source_properties(source)
    assert(props, 'Properties failed')
    assert(obs.obs_properties_get(props, 'interval'), 'Grouped numeric field missing')
    obs.obs_properties_destroy(props)
    obs.obs_source_release(source)
    obs.obs_data_release(settings)
end)
local f = assert(io.open('verification/test-result.txt', 'w'))
f:write(passed and 'PASS: registration, properties, graphics smoke\n' or ('FAIL: ' .. tostring(why) .. '\n'))
f:close()
