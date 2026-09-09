-- Real OBS LuaJIT/data/properties, with an explicitly simulated source/decoder.
local obs = obslua
local count = 0
local function check(ok, message) assert(ok, message); count = count + 1 end
local function near(a, b, tolerance) return math.abs(a - b) <= (tolerance or 1e-7) end
local function test()
    local definition
    obs.obs_register_source = function(d) definition = d end
    obs.obs_frontend_add_event_callback = function() end
    obs.obs_frontend_remove_event_callback = function() end
    dofile('ambient-source-events.lua')
    script_load()
    script_load = nil
    local source = definition
    local real = {}
    local function replace(name, fn) real[name] = obs[name]; obs[name] = fn end
    replace('gs_effect_create', function() return {} end)
    replace('gs_effect_get_param_by_name', function(_, name) return name end)
    replace('gs_effect_destroy', function() end)
    replace('obs_enter_graphics', function() end)
    replace('obs_leave_graphics', function() end)
    local rendered_alpha, rendered_offset_x, rendered_offset_y, rendered_wipe_x, rendered_wipe_y
    local rendered_wipe_progress, rendered_wipe_mode, rendered_wipe_softness
    local rendered_zoom_visible, bypassed
    local rendered_translate_x, rendered_translate_y, rendered_scale_x, rendered_scale_y
    local matrix_depth = 0
    replace('obs_source_skip_video_filter', function() bypassed = true end)
    replace('obs_source_process_filter_begin', function() return true end)
    replace('obs_source_process_filter_end', function() end)
    replace('gs_effect_set_float', function(param, value)
        if param == 'opacity' then rendered_alpha = value
        elseif param == 'offset_x' then rendered_offset_x = value
        elseif param == 'offset_y' then rendered_offset_y = value
        elseif param == 'wipe_x' then rendered_wipe_x = value
        elseif param == 'wipe_y' then rendered_wipe_y = value
        elseif param == 'wipe_progress' then rendered_wipe_progress = value
        elseif param == 'wipe_mode' then rendered_wipe_mode = value
        elseif param == 'wipe_softness' then rendered_wipe_softness = value
        elseif param == 'zoom_visible' then rendered_zoom_visible = value end
    end)
    replace('gs_blend_state_push', function() end)
    replace('gs_blend_function', function() end)
    replace('gs_blend_state_pop', function() end)
    replace('gs_matrix_push', function() matrix_depth = matrix_depth + 1 end)
    replace('gs_matrix_pop', function() matrix_depth = matrix_depth - 1 end)
    replace('gs_matrix_translate3f', function(x, y)
        rendered_translate_x, rendered_translate_y = x, y
    end)
    replace('gs_matrix_scale3f', function(x, y)
        rendered_scale_x, rendered_scale_y = x, y
    end)
    replace('obs_source_get_signal_handler', function(p) return p.signals end)
    replace('signal_handler_connect', function(h, signal, callback)
        h[signal] = h[signal] or {}; h[signal][callback] = true
    end)
    replace('signal_handler_disconnect', function(h, signal, callback)
        if h[signal] then h[signal][callback] = nil end
    end)
    replace('obs_source_get_uuid', function(p) return p.uuid end)
    replace('obs_source_get_weak_source', function(p) p.weak = (p.weak or 0) + 1; return {p = p} end)
    replace('obs_weak_source_release', function(w) w.p.weak = w.p.weak - 1 end)
    replace('obs_weak_source_get_source', function(w) return w.p.alive and w.p or nil end)
    replace('obs_source_release', function() end)
    replace('obs_source_get_ref', function(p) return p end)
    replace('obs_source_get_settings', function(p) obs.obs_data_addref(p.settings); return p.settings end)
    replace('obs_source_get_unversioned_id', function(p) return p.kind end)
    replace('obs_source_get_output_flags', function(p) return p.audio and obs.OBS_SOURCE_AUDIO or obs.OBS_SOURCE_VIDEO end)
    replace('obs_filter_get_parent', function(f) return f.parent end)
    replace('obs_filter_get_target', function(f) return f.parent end)
    replace('obs_source_get_base_width', function(p) return p.width or 320 end)
    replace('obs_source_get_base_height', function(p) return p.height or 180 end)
    replace('obs_source_active', function(p) return p.active end)
    replace('obs_source_showing', function(p) return p.showing end)
    replace('obs_source_enabled', function(f) return f.enabled end)
    replace('obs_source_muted', function(p) return p.muted end)
    replace('obs_source_set_muted', function(p, m) p.muted = m end)
    replace('obs_source_update_properties', function() end)
    replace('obs_source_media_get_time', function(p) return p.position end)
    replace('obs_source_media_get_duration', function(p) return p.duration end)
    replace('obs_source_media_get_state', function(p) return p.media_state end)
    replace('obs_source_media_stop', function(p) table.insert(p.commands, 'stop') end)
    replace('obs_source_media_restart', function(p) table.insert(p.commands, 'restart') end)
    replace('obs_source_media_play_pause', function(p, pause) table.insert(p.commands, pause and 'pause' or 'play') end)
    replace('calldata_bool', function(cd, key) return cd[key] end)
    replace('calldata_source', function(cd, key) return cd[key] end)
    local uid = 0
    local function emit(p, signal, cd)
        for cb in pairs(p.signals[signal] or {}) do cb(cd or {}) end
    end
    local function make(options, media, muted, shared, before_tick)
        uid = uid + 1
        local settings = obs.obs_data_create()
        source.get_defaults(settings)
        for k, v in pairs(options or {}) do
            if k:find('effect') or k:find('mode') or k:find('direction') or k:find('easing')
                    or k:find('angle') or k:find('anchor') or k == 'first_display' then
                obs.obs_data_set_int(settings, k, v)
            else obs.obs_data_set_double(settings, k, v) end
        end
        local p = shared
        if not p then
            p = {uuid = 'parent' .. uid, kind = media and 'ffmpeg_source' or 'image_source',
                audio = true, active = true, showing = true, muted = muted or false, alive = true,
                media_state = obs.OBS_MEDIA_STATE_ENDED, position = 3000, duration = 3000,
                settings = obs.obs_data_create(), commands = {}, signals = {}}
            obs.obs_data_set_bool(p.settings, 'is_local_file', true)
            obs.obs_data_set_int(p.settings, 'speed_percent', 100)
        end
        local f = {uuid = 'filter' .. uid, settings = settings, parent = p, enabled = true, signals = {}}
        local d = source.create(settings, f)
        if before_tick then before_tick(d, p, f) end
        source.video_tick(d, 0)
        return d, p, f
    end
    local function tick(d, p, dt, advance)
        for _, cmd in ipairs(p.commands) do
            if cmd == 'stop' then p.media_state, p.position = obs.OBS_MEDIA_STATE_STOPPED, 0
            elseif cmd == 'restart' then
                p.media_state, p.position = obs.OBS_MEDIA_STATE_PLAYING, 0
                p.restarts = (p.restarts or 0) + 1
                emit(p, 'media_restart'); emit(p, 'media_started')
            elseif cmd == 'pause' then p.media_state = obs.OBS_MEDIA_STATE_PAUSED
            elseif cmd == 'play' and p.media_state == obs.OBS_MEDIA_STATE_PAUSED then p.media_state = obs.OBS_MEDIA_STATE_PLAYING end
        end
        p.commands = {}
        if advance ~= false and p.media_state == obs.OBS_MEDIA_STATE_PLAYING then
            p.position = p.position + dt * 1000 * (obs.obs_data_get_int(p.settings, 'speed_percent') / 100)
            if p.position >= 3000 then p.media_state = obs.OBS_MEDIA_STATE_ENDED; emit(p, 'media_ended') end
        end
        source.video_tick(d, dt)
        script_tick()
    end
    local function destroy(d, p, f, keep_parent)
        source.destroy(d)
        check(d.effect == nil, 'Shader resource released')
        for i = 1, 3 do script_tick() end
        check((p.weak or 0) == 0 or keep_parent, 'Weak references released')
        obs.obs_data_release(f.settings)
        if not keep_parent then obs.obs_data_release(p.settings) end
    end
    local d, p, f = make({first_display = 1, interval = 30}, false, false, nil, function(d)
        bypassed, rendered_alpha = false, nil
        source.video_render(d)
        check(not bypassed and rendered_alpha == 0, 'Before first tick there is no unfiltered flash')
        check(d.generation == 0 and d.wait_left == 0 and not d.owns, 'Rendering does not acquire or advance time')
    end)
    check(d.state == 'WAITING' and p.muted and d.alpha == 0, 'Initial wait and mute')
    tick(d, p, 29.75); check(near(d.wait_left, 0.25), 'Fractional wait')
    p.active = false; tick(d, p, 100); check(near(d.wait_left, 0.25), 'Inactive waiting frozen')
    p.active = true; tick(d, p, 0.25); check(d.state == 'STARTING' and d.alpha == 0, 'Starts after wait')
    tick(d, p, 0.25); check(near(d.alpha, 0.5) and not p.muted, 'Fade in halfway')
    tick(d, p, 0.25); check(d.state == 'VISIBLE' and d.alpha == 1, 'Full visibility')
    tick(d, p, 4.25); check(d.state == 'ENDING' and near(d.alpha, 0.5), 'Fade out halfway')
    tick(d, p, 0.25); check(d.state == 'WAITING' and p.muted and near(d.wait_left, 30), 'Total includes fades')
    f.enabled = false; source.video_tick(d, 0)
    check(not p.muted and d.alpha == 1, 'Disable restores mute and opacity')
    bypassed = false; source.video_render(d)
    check(bypassed, 'Disabled filter passes original pixels')
    f.enabled = true
    bypassed, rendered_alpha = false, nil; source.video_render(d)
    check(not bypassed and rendered_alpha == 0, 'Re-enable before next tick does not flash')
    source.video_tick(d, 0)
    check(d.state == 'WAITING' and near(d.wait_left, 30), 'Re-enable resets initial policy')
    destroy(d, p, f)

    d, p, f = make({duration_mode = 1, display_duration = 5}, false)
    tick(d, p, 5.5); check(d.state == 'ENDING' and near(d.alpha, 1), 'Excluded fade total is six')
    tick(d, p, 0.5); check(d.state == 'WAITING', 'Excluded fade ends at six')
    destroy(d, p, f)
    d, p, f = make({display_duration = 1, start_duration = 4, end_duration = 2}, false)
    tick(d, p, 1/3); check(near(d.alpha, 0.5), 'Oversized fades scale proportionally')
    tick(d, p, 1/3); check(near(d.alpha, 1), 'Oversized fades meet without negative hold')
    tick(d, p, 1/3); check(d.state == 'WAITING', 'Oversized fades preserve total')
    destroy(d, p, f)
    d, p, f = make({interval = 0, display_duration = 0.01, start_effect = 0, end_effect = 0}, false, true)
    check(d.alpha == 1 and p.muted, 'Originally muted remains muted when visible')
    for i = 1, 300 do tick(d, p, 1/60); check(d.alpha == 0 or d.alpha == 1, 'Zero intervals bounded') end
    destroy(d, p, f)
    d, p, f = make({display_duration = 2, start_effect = 0, end_effect = 1, end_duration = 0.5}, false)
    check(d.alpha == 1 and d.state == 'VISIBLE', 'No start effect shows immediately')
    tick(d, p, 1.75); check(near(d.alpha, 0.5) and d.state == 'ENDING', 'End fade works independently')
    tick(d, p, 0.25); check(d.alpha == 0 and p.muted, 'End-only fade finishes hidden and muted')
    destroy(d, p, f)
    d, p, f = make({display_duration = 2, start_effect = 1, start_duration = 0.5, end_effect = 0}, false)
    tick(d, p, 0.25); check(near(d.alpha, 0.5), 'Start fade works without end fade')
    tick(d, p, 1.74); check(d.alpha == 1, 'No end effect keeps full alpha until duration')
    tick(d, p, 0.01); check(d.alpha == 0 and p.muted, 'No end effect still hides at the boundary')
    destroy(d, p, f)

    d, p, f = make({display_duration = 2, start_effect = 2, start_duration = 0.5,
        end_effect = 2, end_duration = 0.5}, false)
    check(d.state == 'STARTING' and d.alpha == 1 and d.start_progress == 0 and p.muted,
        'Peek starts fully outside without changing opacity')
    local start_offsets = {
        {0, 1}, {-0.5625, 1}, {-1, 0}, {-0.5625, -1},
        {0, -1}, {0.5625, -1}, {1, 0}, {0.5625, 1},
    }
    for direction_index, expected in ipairs(start_offsets) do
        d.cfg.start_direction = direction_index - 1
        rendered_offset_x, rendered_offset_y = nil, nil
        source.video_render(d)
        check(near(rendered_offset_x, expected[1]) and near(rendered_offset_y, expected[2]),
            'Peek In direction offset ' .. (direction_index - 1))
    end
    d.cfg.start_direction, d.cfg.start_angle = 8, 315
    source.video_render(d)
    check(near(rendered_offset_x, 0.5625) and near(rendered_offset_y, 1),
        'Custom 315 degree Peek In uses clockwise angle definition')
    d.cfg.start_direction = 2
    tick(d, p, 0.25); source.video_render(d)
    check(near(rendered_offset_x, -0.5) and near(rendered_offset_y, 0) and d.alpha == 1,
        'Peek In moves linearly without opacity change')
    tick(d, p, 0.25); source.video_render(d)
    check(d.state == 'VISIBLE' and rendered_offset_x == 0 and rendered_offset_y == 0,
        'Peek reaches the unchanged normal position')
    tick(d, p, 1.25); source.video_render(d)
    check(d.state == 'ENDING' and near(rendered_offset_x, -0.5) and near(rendered_offset_y, 0)
            and d.alpha == 1,
        'Peek Out moves in its own default left direction')
    tick(d, p, 0.25)
    check(d.state == 'WAITING' and p.muted, 'Peek Out finishes fully hidden')
    destroy(d, p, f)

    d, p, f = make({display_duration = 2, start_effect = 3, start_duration = 0.5,
        end_effect = 3, end_duration = 0.5}, false)
    check(d.state == 'STARTING' and d.alpha == 1 and d.start_progress == 0 and p.muted,
        'Wipe starts fully hidden without changing opacity')
    local wipe_directions = {
        {0, -1}, {math.sqrt(0.5), -math.sqrt(0.5)}, {1, 0},
        {math.sqrt(0.5), math.sqrt(0.5)}, {0, 1},
        {-math.sqrt(0.5), math.sqrt(0.5)}, {-1, 0},
        {-math.sqrt(0.5), -math.sqrt(0.5)},
    }
    for direction_index, expected in ipairs(wipe_directions) do
        d.cfg.start_direction = direction_index - 1
        source.video_render(d)
        check(near(rendered_wipe_x, expected[1]) and near(rendered_wipe_y, expected[2])
                and rendered_wipe_progress == 0 and rendered_wipe_mode == 1
                and rendered_wipe_softness == 0,
            'Wipe In boundary direction ' .. (direction_index - 1))
    end
    d.cfg.start_direction, d.cfg.start_angle = 8, 30
    source.video_render(d)
    check(near(rendered_wipe_x, 0.5) and near(rendered_wipe_y, -math.sqrt(0.75)),
        'Custom 30 degree Wipe uses clockwise angle definition')
    d.cfg.start_direction = 2
    tick(d, p, 0.25); source.video_render(d)
    check(rendered_wipe_x == 1 and rendered_wipe_y == 0
            and near(rendered_wipe_progress, 0.5) and rendered_wipe_mode == 1 and d.alpha == 1,
        'Wipe In boundary advances linearly without opacity change')
    tick(d, p, 0.25); source.video_render(d)
    check(d.state == 'VISIBLE' and rendered_wipe_mode == 0 and rendered_offset_x == 0
            and rendered_offset_y == 0,
        'Wipe reaches normal unshifted display')
    tick(d, p, 1.25); source.video_render(d)
    check(d.state == 'ENDING' and rendered_wipe_x == -1 and rendered_wipe_y == 0
            and near(rendered_wipe_progress, 0.5) and rendered_wipe_mode == 2 and d.alpha == 1,
        'Wipe Out uses its independent default left direction')
    tick(d, p, 0.25)
    check(d.state == 'WAITING' and p.muted, 'Wipe Out finishes fully hidden')
    destroy(d, p, f)

    d, p, f = make({display_duration = 2, start_effect = 3, start_duration = 0.5,
        start_softness = 5, end_effect = 3, end_duration = 0.5,
        end_softness = 25, start_direction = 2, end_direction = 2}, false)
    p.width, p.height = 1920, 1080
    check(d.cfg.start_softness == 5 and d.cfg.end_softness == 25,
        'Wipe start and end Softness settings are independent')
    local softness_cases = {
        {5, 2, 0}, {10, 4, 0}, {25, 3, 0}, {100, 8, 30},
    }
    for _, case in ipairs(softness_cases) do
        d.cfg.start_softness, d.cfg.start_direction, d.cfg.start_angle = case[1], case[2], case[3]
        source.video_render(d)
        local span = math.abs(rendered_wipe_x) + math.abs(rendered_wipe_y)
        local units_per_pixel = math.sqrt((rendered_wipe_x / p.width) ^ 2
            + (rendered_wipe_y / p.height) ^ 2)
        local pixel_width = rendered_wipe_softness * span / units_per_pixel
        check(near(pixel_width, case[1] / 100 * p.height, 1e-6),
            case[1] .. ' percent Softness uses source height for direction ' .. case[2])
    end
    d.cfg.start_softness, d.cfg.start_direction = 10, 2
    p.width = 3840
    source.video_render(d)
    check(near(rendered_wipe_softness * p.width, 108),
        'Horizontal Softness remains 108 pixels when only source width changes')
    p.width = 1920
    d.cfg.start_softness, d.cfg.start_direction = 5, 2
    source.video_render(d)
    check(near(rendered_wipe_softness * p.width, 54),
        'Five percent Softness on 1080-high source is 54 pixels')
    local function test_easing(t, mode)
        if mode == 0 then return t end
        if mode == 1 then return t * t * t end
        if mode == 2 then return 1 - (1 - t) ^ 3 end
        return t < 0.5 and 4 * t * t * t or 1 - ((-2 * t + 2) ^ 3) / 2
    end
    local function smoothstep(a, b, x)
        local t = math.max(0, math.min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    end
    local function soft_mask(position, center, width, wipe_mode)
        local gradient = smoothstep(center - width * 0.5, center + width * 0.5, position)
        return wipe_mode == 1 and 1 - gradient or gradient
    end
    local endpoint_times = {0, 1e-6, 0.5, 1 - 1e-6, 1}
    for _, percent in ipairs({0, 15, 50, 100}) do
        local width = percent / 100 * p.height / p.width
        for easing_mode = 0, 3 do
            for wipe_mode = 1, 2 do
                d.state = wipe_mode == 1 and 'STARTING' or 'ENDING'
                d.cfg.start_direction, d.cfg.end_direction = 2, 2
                d.cfg.start_softness, d.cfg.end_softness = percent, percent
                local masks = {}
                local midpoint_mask
                for time_index, raw in ipairs(endpoint_times) do
                    local eased = test_easing(raw, easing_mode)
                    if wipe_mode == 1 then d.start_progress = eased else d.end_progress = eased end
                    source.video_render(d)
                    local expected_center = percent == 0 and eased
                        or eased * (1 + width) - width * 0.5
                    check(near(rendered_wipe_progress, expected_center, 1e-12),
                        percent .. '% mode ' .. wipe_mode .. ' easing ' .. easing_mode
                            .. ' boundary center at sample ' .. time_index)
                    if percent > 0 then
                        masks[time_index] = {}
                        for position_index, position in ipairs({0, 0.25, 0.5, 0.75, 1}) do
                            masks[time_index][position_index] =
                                soft_mask(position, rendered_wipe_progress,
                                    rendered_wipe_softness, wipe_mode)
                        end
                        if time_index == 3 then
                            midpoint_mask = soft_mask(rendered_wipe_progress,
                                rendered_wipe_progress, rendered_wipe_softness, wipe_mode)
                        end
                    else
                        check(rendered_wipe_softness == 0 and near(rendered_wipe_progress, eased),
                            'Zero Softness preserves hard Wipe progress exactly')
                    end
                end
                if percent > 0 then
                    local at_start, at_end = wipe_mode == 1 and 0 or 1, wipe_mode == 1 and 1 or 0
                    for position_index = 1, 5 do
                        check(near(masks[1][position_index], at_start, 1e-12)
                                and near(masks[5][position_index], at_end, 1e-12),
                            percent .. '% mode ' .. wipe_mode .. ' easing ' .. easing_mode
                                .. ' reaches exact endpoints at position ' .. position_index)
                        check(math.abs(masks[2][position_index] - masks[1][position_index]) < 1e-4
                                and math.abs(masks[5][position_index] - masks[4][position_index]) < 1e-4,
                            percent .. '% mode ' .. wipe_mode .. ' easing ' .. easing_mode
                                .. ' remains continuous near endpoints at position ' .. position_index)
                    end
                    check(near(midpoint_mask, 0.5, 1e-12),
                        percent .. '% mode ' .. wipe_mode .. ' easing ' .. easing_mode
                            .. ' keeps the centered midpoint gradient')
                end
            end
        end
    end
    d.state, d.start_progress, d.end_progress = 'STARTING', 0, 0
    d.cfg.start_softness, d.cfg.end_softness = 5, 25
    tick(d, p, 1.75); source.video_render(d)
    check(d.state == 'ENDING' and near(rendered_wipe_softness * p.width, 270),
        'Wipe Out uses its independent 25 percent Softness')
    destroy(d, p, f)

    d, p, f = make({display_duration = 2, start_effect = 3, start_softness = -5,
        end_effect = 3, end_softness = 125}, false)
    check(d.cfg.start_softness == 0 and d.cfg.end_softness == 100,
        'Stored Softness values clamp to zero through 100 percent')
    destroy(d, p, f)

    d, p, f = make({display_duration = 2, start_effect = 4, start_duration = 0.5,
        start_zoom_percent = 50, start_zoom_anchor = 4, end_effect = 4, end_duration = 0.5,
        end_zoom_percent = 50, end_zoom_anchor = 8}, false)
    check(d.state == 'STARTING' and d.alpha == 1 and d.start_progress == 0,
        'Zoom In starts at its configured scale without changing opacity')
    local anchors = {
        {0, 0}, {0.5, 0}, {1, 0}, {0, 0.5}, {0.5, 0.5},
        {1, 0.5}, {0, 1}, {0.5, 1}, {1, 1},
    }
    for anchor_index, anchor in ipairs(anchors) do
        d.cfg.start_zoom_anchor = anchor_index - 1
        source.video_render(d)
        check(near(rendered_scale_x, 0.5) and near(rendered_scale_y, 0.5)
                and near(rendered_translate_x, 320 * anchor[1] * 0.5)
                and near(rendered_translate_y, 180 * anchor[2] * 0.5),
            'Zoom anchor calculation ' .. (anchor_index - 1))
    end
    d.cfg.start_zoom_anchor = 4
    tick(d, p, 0.25); source.video_render(d)
    check(near(rendered_scale_x, 0.75) and near(rendered_scale_y, 0.75)
            and near(rendered_translate_x, 40) and near(rendered_translate_y, 22.5)
            and rendered_zoom_visible == 1 and d.alpha == 1,
        '50 to 100 percent Zoom In is linear, centered, aspect-preserving, and opacity-neutral')
    tick(d, p, 0.25); source.video_render(d)
    check(d.state == 'VISIBLE' and rendered_scale_x == 1 and rendered_scale_y == 1,
        'Zoom In reaches unchanged 100 percent')
    tick(d, p, 1.25); source.video_render(d)
    check(d.state == 'ENDING' and near(rendered_scale_x, 0.75) and near(rendered_scale_y, 0.75)
            and near(rendered_translate_x, 80) and near(rendered_translate_y, 45)
            and d.cfg.start_zoom_anchor == 4 and d.cfg.end_zoom_anchor == 8,
        '100 to 50 percent Zoom Out uses its independent bottom-right anchor')
    check(source.get_width(d) == 320 and source.get_height(d) == 180,
        'Zoom preserves reported source dimensions while drawing beyond them')
    destroy(d, p, f)

    d, p, f = make({display_duration = 2, start_effect = 4, start_duration = 0.5,
        start_zoom_percent = 150, start_zoom_anchor = 2, end_effect = 4, end_duration = 0.5,
        end_zoom_percent = 200, end_zoom_anchor = 6}, false)
    source.video_render(d)
    check(near(rendered_scale_x, 1.5) and near(rendered_scale_y, 1.5)
            and near(rendered_translate_x, -160) and rendered_translate_y == 0,
        'Zoom In supports above 100 percent from the top-right anchor')
    tick(d, p, 1.75); source.video_render(d)
    check(d.state == 'ENDING' and near(rendered_scale_x, 1.5) and near(rendered_scale_y, 1.5)
            and rendered_translate_x == 0 and near(rendered_translate_y, -90),
        'Zoom Out supports above 100 percent with an independent bottom-left anchor')
    destroy(d, p, f)

    d, p, f = make({display_duration = 1, start_effect = 4, start_duration = 0.5,
        start_zoom_percent = 0, end_effect = 0}, false)
    rendered_scale_x, rendered_scale_y, rendered_translate_x, rendered_translate_y = nil, nil, nil, nil
    source.video_render(d)
    check(rendered_zoom_visible == 0 and rendered_scale_x == nil and rendered_scale_y == nil
            and d.alpha == 1 and p.muted,
        'Zero percent Zoom renders transparent without a singular matrix or opacity change')
    tick(d, p, 0.25); source.video_render(d)
    check(near(rendered_scale_x, 0.5) and near(rendered_scale_y, 0.5)
            and rendered_zoom_visible == 1 and not p.muted,
        'Zero percent Zoom enters the normal linear scale path after its endpoint')
    destroy(d, p, f)
    check(matrix_depth == 0, 'Zoom rendering restores the graphics matrix stack')

    local curves = {
        {name = 'Linear', value = 0, samples = {0.25, 0.5, 0.75}},
        {name = 'Ease In', value = 1, samples = {0.015625, 0.125, 0.421875}},
        {name = 'Ease Out', value = 2, samples = {0.578125, 0.875, 0.984375}},
        {name = 'Ease In/Out', value = 3, samples = {0.0625, 0.5, 0.9375}},
    }
    for _, curve in ipairs(curves) do
        d, p, f = make({display_duration = 3, start_effect = 1, start_duration = 1,
            start_easing = curve.value, end_effect = 0}, false)
        check(d.start_progress == 0 and d.alpha == 0,
            curve.name .. ' preserves the zero endpoint')
        for step = 1, 100 do
            tick(d, p, 0.01)
            check(d.start_progress >= 0 and d.start_progress <= 1,
                curve.name .. ' remains in the unit interval ' .. step)
            if step % 25 == 0 then
                local index = step / 25
                local expected = index == 4 and 1 or curve.samples[index]
                check(near(d.start_progress, expected), curve.name .. ' sample ' .. index)
            end
        end
        tick(d, p, 1)
        check(d.start_progress == 1 and d.alpha == 1,
            curve.name .. ' preserves the one endpoint')
        destroy(d, p, f)
    end

    local function reset_rendered()
        rendered_alpha, rendered_offset_x, rendered_offset_y = nil, nil, nil
        rendered_wipe_x, rendered_wipe_y = nil, nil
        rendered_wipe_progress, rendered_wipe_mode, rendered_wipe_softness = nil, nil, nil
        rendered_zoom_visible = nil
        rendered_translate_x, rendered_translate_y = nil, nil
        rendered_scale_x, rendered_scale_y = nil, nil
    end
    local function check_effect_render(effect_value, progress, starting, label)
        reset_rendered()
        source.video_render(d)
        if effect_value == 1 then
            check(near(rendered_alpha, starting and progress or 1 - progress)
                    and rendered_offset_x == 0 and rendered_offset_y == 0
                    and rendered_wipe_mode == 0
                    and rendered_scale_x == 1 and rendered_scale_y == 1,
                label .. ' changes only Fade opacity')
        elseif effect_value == 2 then
            check(rendered_alpha == 1
                    and near(rendered_offset_x, starting and -(1 - progress) or progress)
                    and rendered_offset_y == 0 and rendered_wipe_mode == 0
                    and rendered_scale_x == 1 and rendered_scale_y == 1,
                label .. ' changes only Peek position')
        elseif effect_value == 3 then
            check(rendered_alpha == 1 and rendered_offset_x == 0 and rendered_offset_y == 0
                    and near(rendered_wipe_progress, progress)
                    and rendered_wipe_mode == (starting and 1 or 2)
                    and rendered_wipe_softness == 0
                    and rendered_scale_x == 1 and rendered_scale_y == 1,
                label .. ' changes only Wipe boundary')
        else
            local expected_scale = starting and 0.5 + 0.5 * progress or 1 - 0.5 * progress
            check(rendered_alpha == 1 and rendered_offset_x == 0 and rendered_offset_y == 0
                    and rendered_wipe_mode == 0
                    and near(rendered_scale_x, expected_scale)
                    and near(rendered_scale_y, expected_scale),
                label .. ' changes only Zoom scale')
        end
    end
    local effect_names = {'Fade', 'Peek', 'Wipe', 'Zoom'}
    for effect_value, effect_name in ipairs(effect_names) do
        for _, curve in ipairs(curves) do
            local expected = curve.samples[1]
            d, p, f = make({display_duration = 3, start_effect = effect_value,
                start_duration = 1, start_easing = curve.value, start_direction = 2,
                start_zoom_percent = 50, start_zoom_anchor = 4, end_effect = 0}, false)
            tick(d, p, 0.25)
            check(near(d.start_progress, expected),
                effect_name .. ' start applies ' .. curve.name)
            check_effect_render(effect_value, expected, true,
                effect_name .. ' start ' .. curve.name)
            destroy(d, p, f)

            d, p, f = make({display_duration = 2, start_effect = 0,
                end_effect = effect_value, end_duration = 1, end_easing = curve.value,
                end_direction = 2, end_zoom_percent = 50, end_zoom_anchor = 4}, false)
            tick(d, p, 1.25)
            check(near(d.end_progress, expected),
                effect_name .. ' end applies ' .. curve.name)
            check_effect_render(effect_value, expected, false,
                effect_name .. ' end ' .. curve.name)
            destroy(d, p, f)
        end
    end

    d, p, f = make({display_duration = 2, start_effect = 1, start_easing = 1,
        end_effect = 1, end_easing = 2}, false)
    check(d.cfg.start_easing == 1 and d.cfg.end_easing == 2,
        'Start and end easing settings are independent')
    local legacy_settings = obs.obs_data_create()
    obs.obs_data_set_int(legacy_settings, 'start_effect', 1)
    obs.obs_data_set_int(legacy_settings, 'end_effect', 4)
    source.update(d, legacy_settings)
    check(d.pending_cfg.start_easing == 0 and d.pending_cfg.end_easing == 0
            and d.pending_cfg.start_softness == 0 and d.pending_cfg.end_softness == 0,
        'Stored settings without easing or Softness values use Linear and hard Wipe')
    obs.obs_data_release(legacy_settings)
    destroy(d, p, f)

    d, p, f = make({first_display = 1, interval = -1, random_min = -2, random_max = -3,
        display_duration = -1, start_duration = -1, end_duration = -1}, false)
    check(d.cfg.interval == 0 and d.cfg.lo == 0 and d.cfg.hi == 0, 'Negative stored waits normalize to zero')
    check(d.cfg.duration == 0.01 and d.cfg.fade_in == 0 and d.cfg.fade_out == 0,
        'Negative stored display and fade times respect their different minima')
    destroy(d, p, f)
    d, p, f = make({interval_mode = 1, random_min = 60, random_max = 20, first_display = 1,
        display_duration = 0.01, start_effect = 0, end_effect = 0}, false)
    local previous, different = nil, false
    for i = 1, 1000 do
        check(d.wait_left >= 20 and d.wait_left <= 60, 'Random wait in normalized range')
        different = different or previous ~= nil and previous ~= d.wait_left
        previous = d.wait_left
        local before = d.seed; tick(d, p, d.wait_left / 2)
        check(d.seed == before, 'Random chosen once per wait')
        tick(d, p, d.wait_left); tick(d, p, 0.01)
    end
    check(different, 'Random stream varies'); destroy(d, p, f)
    d, p, f = make({display_duration = 5}, false)
    obs.obs_data_set_double(f.settings, 'display_duration', 2)
    source.update(d, f.settings)
    tick(d, p, 4.9); check(d.state == 'ENDING', 'Config edits do not truncate current event')
    tick(d, p, 0.1); tick(d, p, 30); tick(d, p, 2)
    check(d.state == 'WAITING', 'New config used for next event'); destroy(d, p, f)

    d, p, f = make({interval = 0.5}, true)
    check(not d.ready and p.muted, 'Restart request is not decoder readiness')
    for i = 1, 15 do tick(d, p, 1/60) end
    check(d.ready and near(d.alpha, 0.5), 'Media fade follows current time')
    emit(p, 'media_ended'); tick(d, p, 1/60)
    check(d.state ~= 'WAITING', 'Stale ended notification is ignored while playing')
    p.active = false; source.deactivate(d); tick(d, p, 1/60)
    local position, alpha = p.position, d.alpha
    tick(d, p, 100)
    check(p.position == position and d.alpha == alpha and p.muted, 'Media and fade paused together')
    p.active = true; tick(d, p, 1/60); tick(d, p, 1/60)
    check(p.position > position and not p.muted, 'Media resumes from position')
    for i = 1, 220 do tick(d, p, 1/60) end
    check(p.restarts >= 2, 'Ended source restarts each event')
    f.enabled = false; emit(f, 'enable', {enabled = false})
    check(not p.muted and not d.owns, 'Enable signal immediately restores mute')
    destroy(d, p, f)
    d, p, f = make({}, true)
    p.duration = 0
    tick(d, p, 0.1)
    for i = 1, 28 do tick(d, p, 0.1) end
    check(d.alpha == 1, 'Unknown duration does not predict fade out')
    tick(d, p, 0.11); check(d.state == 'WAITING' and p.muted, 'Unknown duration hides on ended')
    destroy(d, p, f)
    d, p, f = make({}, true)
    for i = 1, 11 do tick(d, p, 1, false) end
    check(d.state == 'WAITING' and p.muted and d.notice ~= '', 'Startup watchdog aborts safely')
    destroy(d, p, f)
    d, p, f = make({}, true)
    obs.obs_data_set_bool(p.settings, 'looping', true)
    tick(d, p, 0.1); check(d.invalid and d.alpha == 0 and p.muted, 'Invalid media config blocks events')
    obs.obs_data_set_bool(p.settings, 'looping', false)
    tick(d, p, 0); check(not d.invalid, 'Corrected conditions allow retry')
    destroy(d, p, f)
    d, p, f = make({}, false)
    local d2, _, f2 = make({}, false, false, p)
    check(d.owns and not d2.owns, 'Duplicate cannot take mute ownership')
    bypassed = false; source.video_render(d2)
    check(bypassed, 'Duplicate does not hide the controlling filter output')
    source.destroy(d2); obs.obs_data_release(f2.settings)
    emit(p, 'filter_remove', {filter = f})
    check(not d.owns and not p.muted, 'Removal restores mute before destruction')
    destroy(d, p, f)

    d, p, f = make({}, true)
    local restarts_before = p.restarts or 0
    p.alive = false
    source.destroy(d)
    emit(p, 'destroy')
    check(not d.owns and d.state == 'DISABLED' and d.alpha == 1,
        'Destroy detaches ownership when parent weak reference is unavailable')
    check((p.restarts or 0) == restarts_before, 'Unavailable parent does not restart media')
    obs.obs_data_release(f.settings); obs.obs_data_release(p.settings)

    local settings = obs.obs_data_create(); source.get_defaults(settings)
    local props = source.get_properties(nil)
    for _, key in ipairs({'interval', 'random_min', 'random_max', 'display_duration', 'start_duration',
            'end_duration', 'start_zoom_percent', 'end_zoom_percent',
            'start_softness', 'end_softness'}) do
        local property = obs.obs_properties_get(props, key)
        check(property ~= nil, 'Numeric property exists: ' .. key)
        check(not obs.obs_property_modified(property, settings), 'Numbers do not rebuild properties: ' .. key)
    end
    obs.obs_data_set_int(settings, 'interval_mode', 1)
    check(obs.obs_property_modified(obs.obs_properties_get(props, 'interval_mode'), settings), 'Mode updates visibility')
    check(not obs.obs_property_visible(obs.obs_properties_get(props, 'interval')), 'Fixed field hidden')
    check(obs.obs_property_visible(obs.obs_properties_get(props, 'random_min')), 'Random field shown')
    check(not obs.obs_property_visible(obs.obs_properties_get(props, 'start_direction')),
        'Peek direction hidden for Fade')
    check(not obs.obs_property_visible(obs.obs_properties_get(props, 'start_softness'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'end_softness')),
        'Fade hides start and end Softness controls')
    local easing_items = {
        '一定', 'ゆっくり始まる', 'ゆっくり終わる',
        'ゆっくり始まり、ゆっくり終わる',
    }
    for _, prefix in ipairs({'start', 'end'}) do
        local property = obs.obs_properties_get(props, prefix .. '_easing')
        check(property ~= nil and obs.obs_property_list_item_count(property) == #easing_items,
            prefix .. ' easing shows exactly four choices')
        for index, name in ipairs(easing_items) do
            check(obs.obs_property_list_item_name(property, index - 1) == name
                    and obs.obs_property_list_item_int(property, index - 1) == index - 1,
                prefix .. ' easing label and stored value ' .. index)
        end
    end
    check(obs.obs_data_get_int(settings, 'start_easing') == 0
            and obs.obs_data_get_int(settings, 'end_easing') == 0
            and obs.obs_data_get_double(settings, 'start_softness') == 0
            and obs.obs_data_get_double(settings, 'end_softness') == 0,
        'Easing defaults to Linear and start/end Softness default to zero')
    obs.obs_data_set_int(settings, 'start_effect', 0)
    obs.obs_data_set_int(settings, 'end_effect', 0)
    check(obs.obs_property_modified(obs.obs_properties_get(props, 'start_effect'), settings)
            and obs.obs_property_modified(obs.obs_properties_get(props, 'end_effect'), settings)
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'start_easing'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'end_easing'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'start_softness'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'end_softness')),
        'No effect hides start/end easing and Softness controls')
    obs.obs_data_set_int(settings, 'start_effect', 2)
    check(obs.obs_property_modified(obs.obs_properties_get(props, 'start_effect'), settings),
        'Peek selection updates visibility')
    check(obs.obs_property_visible(obs.obs_properties_get(props, 'start_easing'))
            and obs.obs_property_visible(obs.obs_properties_get(props, 'start_direction'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'start_angle'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'start_softness')),
        'Peek shows easing and direction but hides non-custom angle and Softness')
    obs.obs_data_set_int(settings, 'start_effect', 3)
    check(obs.obs_property_modified(obs.obs_properties_get(props, 'start_effect'), settings)
            and obs.obs_property_visible(obs.obs_properties_get(props, 'start_direction'))
            and obs.obs_property_visible(obs.obs_properties_get(props, 'start_softness')),
        'Wipe selection shows directional and Softness controls')
    for _, prefix in ipairs({'start', 'end'}) do
        local property = obs.obs_properties_get(props, prefix .. '_softness')
        check(property ~= nil and obs.obs_property_float_min(property) == 0
                and obs.obs_property_float_max(property) == 100
                and obs.obs_property_float_step(property) == 1,
            prefix .. ' Softness is zero through 100 percent in one-percent steps')
    end
    obs.obs_data_set_int(settings, 'end_effect', 3)
    check(obs.obs_property_modified(obs.obs_properties_get(props, 'end_effect'), settings)
            and obs.obs_property_visible(obs.obs_properties_get(props, 'end_softness')),
        'Wipe Out independently shows its Softness control')
    obs.obs_data_set_int(settings, 'start_direction', 8)
    check(obs.obs_property_modified(obs.obs_properties_get(props, 'start_direction'), settings)
            and obs.obs_property_visible(obs.obs_properties_get(props, 'start_angle')),
        'Custom direction alone shows the angle field')
    obs.obs_data_set_int(settings, 'start_effect', 4)
    check(obs.obs_property_modified(obs.obs_properties_get(props, 'start_effect'), settings)
            and obs.obs_property_visible(obs.obs_properties_get(props, 'start_zoom_anchor'))
            and obs.obs_property_visible(obs.obs_properties_get(props, 'start_zoom_percent'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'start_direction'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'start_angle'))
            and not obs.obs_property_visible(obs.obs_properties_get(props, 'start_softness')),
        'Zoom selection hides Wipe direction, angle, and Softness controls')
    check(obs.obs_data_get_double(settings, 'start_zoom_percent') == 50
            and obs.obs_data_get_double(settings, 'end_zoom_percent') == 50
            and obs.obs_data_get_int(settings, 'start_zoom_anchor') == 4
            and obs.obs_data_get_int(settings, 'end_zoom_anchor') == 4,
        'Zoom defaults are 50 percent and centered independently')
    local anchor_items = {
        {'● 中央', 4}, {'↑ 上', 1}, {'↗ 右上', 2},
        {'→ 右', 5}, {'↘ 右下', 8}, {'↓ 下', 7},
        {'↙ 左下', 6}, {'← 左', 3}, {'↖ 左上', 0},
    }
    for _, prefix in ipairs({'start', 'end'}) do
        local property = obs.obs_properties_get(props, prefix .. '_zoom_anchor')
        check(obs.obs_property_list_item_count(property) == #anchor_items,
            prefix .. ' Zoom shows exactly nine anchors')
        for index, anchor in ipairs(anchor_items) do
            check(obs.obs_property_list_item_name(property, index - 1) == anchor[1]
                    and obs.obs_property_list_item_int(property, index - 1) == anchor[2],
                prefix .. ' Zoom anchor display order and stored value ' .. index)
        end
    end
    check(obs.obs_data_get_int(settings, 'end_direction') == 6,
        'Default Peek directions are start right and end left')
    local product_file=assert(io.open('ambient-source-events.lua','r'))
    local product_source=assert(product_file:read('*a')); product_file:close()
    check(not product_source:find('obs_sceneitem_set_',1,true),
        'Product never changes Scene Item transforms')
    obs.obs_properties_destroy(props); obs.obs_data_release(settings)
    for name, fn in pairs(real) do obs[name] = fn end
end
local ok, reason = xpcall(test, debug.traceback)
-- The harness must see explicit success: obs_script_loaded alone is insufficient.
local f = assert(io.open('verification/test-result.txt', 'w'))
f:write(ok and ('PASS: ' .. count .. ' state/data/property assertions\n') or ('FAIL: ' .. tostring(reason) .. '\n'))
f:close()
script_unload, script_tick = nil, nil
