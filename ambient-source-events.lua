-- SPDX-License-Identifier: GPL-2.0-or-later
-- Ambient Source Events 0.7.0 / OBS Studio 32.0.4
-- Source timing belongs to video_tick; video_render never advances time.
local obs = obslua
local bit = require('bit')
local ID = 'lua_ambient_source_events_v1'
local TITLE = 'ソース定期表示'
local LIMIT, WATCHDOG, ZOOM_UI_MAX = 86400, 10, 1000000
local NONE, FADE, PEEK, WIPE, ZOOM = 0, 1, 2, 3, 4
local LINEAR, EASE_IN, EASE_OUT, EASE_IN_OUT = 0, 1, 2, 3
local instances, owners, restore_jobs = {}, {}, {}
local disconnect_jobs = {}
local exiting, unloading = false, false
local serial = 0

local EFFECT = [[
uniform float4x4 ViewProj;
uniform texture2d image;
uniform float opacity;
uniform float offset_x;
uniform float offset_y;
uniform float wipe_x;
uniform float wipe_y;
uniform float wipe_progress;
uniform float wipe_mode;
uniform float wipe_softness;
uniform float zoom_visible;
sampler_state textureSampler { Filter = Linear; AddressU = Clamp; AddressV = Clamp; };
struct VertData { float4 pos : POSITION; float2 uv : TEXCOORD0; };
VertData VSDefault(VertData v) {
    VertData o; o.pos = mul(float4(v.pos.xyz, 1.0), ViewProj); o.uv = v.uv; return o;
}
float4 PSOpacity(VertData v) : TARGET {
    if (zoom_visible < 0.5)
        return float4(0.0, 0.0, 0.0, 0.0);
    float2 sample_uv = v.uv - float2(offset_x, offset_y);
    if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0)
        return float4(0.0, 0.0, 0.0, 0.0);
    if (wipe_mode > 0.5) {
        float span = abs(wipe_x) + abs(wipe_y);
        float minimum = min(0.0, wipe_x) + min(0.0, wipe_y);
        float position = (dot(v.uv, float2(wipe_x, wipe_y)) - minimum) / span;
        if (wipe_softness <= 0.0) {
            if ((wipe_mode < 1.5 && position > wipe_progress) ||
                    (wipe_mode > 1.5 && position <= wipe_progress))
                return float4(0.0, 0.0, 0.0, 0.0);
        } else {
            float gradient = smoothstep(wipe_progress - wipe_softness * 0.5,
                wipe_progress + wipe_softness * 0.5, position);
            float mask = wipe_mode < 1.5 ? 1.0 - gradient : gradient;
            return image.Sample(textureSampler, sample_uv) * (opacity * mask);
        }
    }
    return image.Sample(textureSampler, sample_uv) * opacity;
}
technique Draw { pass { vertex_shader = VSDefault(v); pixel_shader = PSOpacity(v); } }
]]

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function finite(x) return type(x) == 'number' and x == x and math.abs(x) < math.huge end
local function number(settings, key, default, lo)
    local x = obs.obs_data_get_double(settings, key)
    if not finite(x) then x = default end
    return clamp(x, lo or 0, LIMIT)
end
local function effect(settings, key)
    return clamp(obs.obs_data_get_int(settings, key), NONE, ZOOM)
end
local function easing(settings, key)
    return clamp(obs.obs_data_get_int(settings, key), LINEAR, EASE_IN_OUT)
end
local function eased_progress(t, mode)
    t = clamp(t, 0, 1)
    if t == 0 or t == 1 or mode == LINEAR then return t end
    local value
    if mode == EASE_IN then
        value = t * t * t
    elseif mode == EASE_OUT then
        local remaining = 1 - t
        value = 1 - remaining * remaining * remaining
    else
        value = t < 0.5 and 4 * t * t * t
            or 1 - ((-2 * t + 2) ^ 3) / 2
    end
    return clamp(value, 0, 1)
end
local function direction(settings, key)
    return clamp(obs.obs_data_get_int(settings, key), 0, 8)
end
local function angle(settings, key)
    return obs.obs_data_get_int(settings, key) % 360
end
local function zoom_anchor(settings, key)
    return clamp(obs.obs_data_get_int(settings, key), 0, 8)
end
local function zoom_scale(settings, key)
    local percent = obs.obs_data_get_double(settings, key)
    if not finite(percent) then percent = 50 end
    return clamp(percent, 0, ZOOM_UI_MAX) / 100
end
local function softness(settings, key)
    local percent = obs.obs_data_get_double(settings, key)
    if not finite(percent) then percent = 0 end
    return clamp(percent, 0, 100)
end
local function config(settings)
    local lo = number(settings, 'random_min', 20)
    local hi = number(settings, 'random_max', 60)
    local start_effect = effect(settings, 'start_effect')
    local end_effect = effect(settings, 'end_effect')
    return {
        random = obs.obs_data_get_int(settings, 'interval_mode') == 1,
        interval = number(settings, 'interval', 30),
        lo = math.min(lo, hi), hi = math.max(lo, hi),
        immediate = obs.obs_data_get_int(settings, 'first_display') == 0,
        duration = number(settings, 'display_duration', 5, 0.01),
        include = obs.obs_data_get_int(settings, 'duration_mode') ~= 1,
        start_effect = start_effect, end_effect = end_effect,
        start_easing = start_effect ~= NONE and easing(settings, 'start_easing') or LINEAR,
        end_easing = end_effect ~= NONE and easing(settings, 'end_easing') or LINEAR,
        start_duration = start_effect ~= NONE and number(settings, 'start_duration', 0.5) or 0,
        end_duration = end_effect ~= NONE and number(settings, 'end_duration', 0.5) or 0,
        fade_in = start_effect == FADE and number(settings, 'start_duration', 0.5) or 0,
        fade_out = end_effect == FADE and number(settings, 'end_duration', 0.5) or 0,
        start_direction = direction(settings, 'start_direction'),
        end_direction = direction(settings, 'end_direction'),
        start_angle = angle(settings, 'start_angle'),
        end_angle = angle(settings, 'end_angle'),
        start_softness = softness(settings, 'start_softness'),
        end_softness = softness(settings, 'end_softness'),
        start_zoom_anchor = zoom_anchor(settings, 'start_zoom_anchor'),
        end_zoom_anchor = zoom_anchor(settings, 'end_zoom_anchor'),
        start_zoom_scale = zoom_scale(settings, 'start_zoom_percent'),
        end_zoom_scale = zoom_scale(settings, 'end_zoom_percent'),
    }
end
local function zoom_transform(d, width, height)
    local cfg, scale, anchor_index = d.cfg, 1, 4
    if d.state == 'STARTING' and cfg.start_effect == ZOOM then
        scale = cfg.start_zoom_scale + (1 - cfg.start_zoom_scale) * d.start_progress
        anchor_index = cfg.start_zoom_anchor
    elseif d.state == 'ENDING' and cfg.end_effect == ZOOM then
        scale = 1 + (cfg.end_zoom_scale - 1) * d.end_progress
        anchor_index = cfg.end_zoom_anchor
    else return 1, 0, 0 end
    local anchor_x = (anchor_index % 3) / 2
    local anchor_y = math.floor(anchor_index / 3) / 2
    return scale, width * anchor_x * (1 - scale), height * anchor_y * (1 - scale)
end
local function envelope(t, total, cfg)
    local si, so = cfg.start_duration, cfg.end_duration
    if total and si + so > total then
        local scale = total / (si + so)
        si, so = si * scale, so * scale
    end
    local raw_start = si > 0 and clamp(t / si, 0, 1) or 1
    local raw_end = total and so > 0 and clamp((t - (total - so)) / so, 0, 1) or 0
    local start_progress = eased_progress(raw_start, cfg.start_easing)
    local end_progress = eased_progress(raw_end, cfg.end_easing)
    local alpha = cfg.start_effect == FADE and start_progress or 1
    if cfg.end_effect == FADE then alpha = math.min(alpha, 1 - end_progress) end
    local phase = si > 0 and t < si and 'STARTING' or 'VISIBLE'
    if total and so > 0 and t >= total - so then phase = 'ENDING' end
    return alpha, phase, start_progress, end_progress
end
local function direction_unit(direction_index, custom_angle)
    local degrees = direction_index == 8 and custom_angle or direction_index * 45
    local radians = math.rad(degrees)
    local ux, uy = math.sin(radians), -math.cos(radians)
    if math.abs(ux) < 1e-12 then ux = 0 end
    if math.abs(uy) < 1e-12 then uy = 0 end
    return ux, uy
end
local function peek_offset(d, width, height)
    local cfg, direction_index, progress, sign = d.cfg
    if d.state == 'STARTING' and cfg.start_effect == PEEK then
        direction_index, progress, sign = cfg.start_direction, 1 - d.start_progress, -1
    elseif d.state == 'ENDING' and cfg.end_effect == PEEK then
        direction_index, progress, sign = cfg.end_direction, d.end_progress, 1
    else return 0, 0 end
    if width <= 0 or height <= 0 or progress <= 0 then return 0, 0 end
    local custom_angle = d.state == 'STARTING' and cfg.start_angle or cfg.end_angle
    local ux, uy = direction_unit(direction_index, custom_angle)
    local distance = math.min(ux ~= 0 and width / math.abs(ux) or math.huge,
        uy ~= 0 and height / math.abs(uy) or math.huge)
    return sign * ux * distance * progress / width,
        sign * uy * distance * progress / height
end
local function effect_direction(d, effect_type)
    local cfg, direction_index, progress, mode = d.cfg
    if d.state == 'STARTING' and cfg.start_effect == effect_type then
        direction_index, progress, mode = cfg.start_direction, d.start_progress, 1
    elseif d.state == 'ENDING' and cfg.end_effect == effect_type then
        direction_index, progress, mode = cfg.end_direction, d.end_progress, 2
    else return 0, 0, 0, 0 end
    local custom_angle = d.state == 'STARTING' and cfg.start_angle or cfg.end_angle
    local ux, uy = direction_unit(direction_index, custom_angle)
    return ux, uy, progress, mode
end
local function wipe_parameters(d, width, height)
    local ux, uy, progress, mode = effect_direction(d, WIPE)
    if mode == 0 or width <= 0 or height <= 0 then return ux, uy, progress, mode, 0 end
    local percent = d.state == 'STARTING' and d.cfg.start_softness or d.cfg.end_softness
    if percent <= 0 then return ux, uy, progress, mode, 0 end
    local span = math.abs(ux) + math.abs(uy)
    local units_per_pixel = math.sqrt((ux / width) ^ 2 + (uy / height) ^ 2)
    -- Convert the source-height-based pixel width into the shader's existing
    -- normalized boundary coordinate without changing Wipe direction/progress.
    local normalized = (percent / 100) * height * units_per_pixel / span
    -- The centered gradient extends by half its width on each side. Move its
    -- center fully outside both edges so the complete gradient crosses within
    -- the effect duration, without endpoint-only overrides in the shader.
    local center = progress * (1 + normalized) - normalized * 0.5
    return ux, uy, center, mode, normalized
end
local function log(d, message)
    if d.notice == message then return end
    d.notice = message
    if message ~= '' then obs.script_log(obs.LOG_WARNING, TITLE .. ': ' .. message) end
    if d.context and not d.destroyed then obs.obs_source_update_properties(d.context) end
end
local function with_parent(d, fn)
    local p = d.parent and obs.obs_weak_source_get_source(d.parent)
    if not p then return end
    fn(p)
    obs.obs_source_release(p)
end
local function remember(d, owned)
    if d.destroyed then return end
    local s = obs.obs_source_get_settings(d.context)
    obs.obs_data_set_bool(s, '_ase_owned', owned)
    obs.obs_data_set_bool(s, '_ase_original_muted', d.original_muted or false)
    obs.obs_data_set_string(s, '_ase_parent_uuid', d.parent_uuid or '')
    obs.obs_data_set_string(s, '_ase_filter_uuid', obs.obs_source_get_uuid(d.context))
    obs.obs_data_release(s)
end
local function mute(d, p, hidden)
    if d.owns and d.has_audio then
        local desired = hidden or d.original_muted
        if obs.obs_source_muted(p) ~= desired then obs.obs_source_set_muted(p, desired) end
    end
end
local function cancel_restore(uuid)
    local job = restore_jobs[uuid]
    if job then obs.obs_weak_source_release(job.parent); restore_jobs[uuid] = nil end
end
local function normal_playback(p)
    local state = obs.obs_source_media_get_state(p)
    if state == obs.OBS_MEDIA_STATE_PAUSED then
        obs.obs_source_media_play_pause(p, false)
        return true
    elseif state == obs.OBS_MEDIA_STATE_PLAYING or state == obs.OBS_MEDIA_STATE_OPENING
            or state == obs.OBS_MEDIA_STATE_BUFFERING then
        return true
    elseif obs.obs_source_showing(p) then
        obs.obs_source_media_restart(p)
        obs.obs_source_media_play_pause(p, false)
        return true
    end
    return false
end
local function release_control(d, p, resume)
    if not d.owns then return end
    if d.has_audio then obs.obs_source_set_muted(p, d.original_muted) end
    owners[d.parent_uuid] = nil
    d.owns, d.alpha, d.state = false, 1, 'DISABLED'
    remember(d, false)
    if resume and d.media and not exiting then
        -- A queued pause/stop must precede the restoration command.
        if d.paused_by_us then obs.obs_source_media_play_pause(p, false) end
        cancel_restore(d.parent_uuid)
        restore_jobs[d.parent_uuid] = {
            parent = obs.obs_source_get_weak_source(p), frames = 0,
        }
    end
    d.paused_by_us, d.control_enabled = false, false
end
local function disconnect(d, p)
    if d.connections then
        local handler = p and obs.obs_source_get_signal_handler(p)
        if handler then
            for name, callback in pairs(d.connections) do
                obs.signal_handler_disconnect(handler, name, callback)
            end
        end
        d.connections = nil
    end
end
local function defer_disconnect(d, p)
    if d.connections then
        disconnect_jobs[#disconnect_jobs + 1] = {
            source = obs.obs_source_get_ref(p), connections = d.connections,
        }
        d.connections = nil
    end
end
local function flush_disconnects()
    local jobs = disconnect_jobs
    disconnect_jobs = {}
    for _, job in ipairs(jobs) do
        local handler = obs.obs_source_get_signal_handler(job.source)
        for name, callback in pairs(job.connections) do
            obs.signal_handler_disconnect(handler, name, callback)
        end
        obs.obs_source_release(job.source)
    end
end
local function detach(d, resume, deferred)
    with_parent(d, function(p)
        release_control(d, p, resume)
        if deferred then defer_disconnect(d, p) else disconnect(d, p) end
    end)
    if d.owns then
        if owners[d.parent_uuid] == d then owners[d.parent_uuid] = nil end
        d.owns, d.control_enabled, d.paused_by_us = false, false, false
        d.alpha, d.state = 1, 'DISABLED'
    end
    if d.parent then obs.obs_weak_source_release(d.parent) end
    d.parent, d.parent_uuid = nil, nil
end
local function attach(d, p)
    if d.parent_uuid == obs.obs_source_get_uuid(p) then return end
    detach(d, false)
    d.parent_uuid = obs.obs_source_get_uuid(p)
    d.parent = obs.obs_source_get_weak_source(p)
    local handler = obs.obs_source_get_signal_handler(p)
    d.connections = {
        destroy = function(cd)
            -- A borrowed source is still valid during its destroy signal.
            local parent = obs.calldata_source(cd, 'source')
            if parent then
                release_control(d, parent, false)
                disconnect(d, parent)
            end
            d.detached = true
        end,
        media_restart = function()
            if d.owns and d.request_pending then d.restart_ack = d.generation end
        end,
        media_started = function()
            if d.owns then d.started_signal = d.generation end
        end,
        media_ended = function()
            if d.owns then d.ended_signal = d.generation end
        end,
        filter_remove = function(cd)
            if obs.calldata_source(cd, 'filter') == d.context then
                d.detached = true
                with_parent(d, function(parent) release_control(d, parent, true) end)
            end
        end,
    }
    for name, callback in pairs(d.connections) do obs.signal_handler_connect(handler, name, callback) end
end
local function inspect_parent(d, p)
    local settings = obs.obs_source_get_settings(p)
    local media = obs.obs_source_get_unversioned_id(p) == 'ffmpeg_source'
        and obs.obs_data_get_bool(settings, 'is_local_file')
    local err = ''
    if media then
        if obs.obs_data_get_bool(settings, 'looping') then err = 'Media Sourceの「繰り返し」をOFFにしてください。'
        elseif obs.obs_data_get_bool(settings, 'restart_on_activate') then
            err = 'Media Sourceの「ソースがアクティブになったときに再生を再開する」をOFFにしてください。'
        elseif obs.obs_data_get_bool(settings, 'close_when_inactive') then
            err = 'Media Sourceの「非アクティブ時にファイルを閉じる」をOFFにしてください。'
        end
    end
    local speed = obs.obs_data_get_int(settings, 'speed_percent') / 100
    local file = media and obs.obs_data_get_string(settings, 'local_file') or ''
    obs.obs_data_release(settings)
    if speed <= 0 or speed > 2 then speed = 1 end
    return media, speed, file, err
end
local function random_wait(d)
    if not d.cfg.random then return d.cfg.interval end
    -- Independent Park-Miller streams; never reseed Lua's shared PRNG.
    d.seed = d.seed * 16807 % 2147483647
    return d.cfg.lo + (d.cfg.hi - d.cfg.lo) * ((d.seed - 1) / 2147483646)
end
local function apply_pending(d)
    if d.pending_cfg then d.cfg, d.pending_cfg = d.pending_cfg, nil end
end
local function waiting(d, initial)
    apply_pending(d)
    d.state, d.alpha, d.elapsed = 'WAITING', 0, 0
    d.start_progress, d.end_progress = 0, 0
    d.wait_left = initial and d.cfg.immediate and 0 or random_wait(d)
    d.request_pending, d.ready, d.paused_by_us = false, false, false
    d.watchdog, d.last_position = 0, nil
    d.before_restart, d.before_restart_active = nil, nil
    d.restart_observed_position, d.rewind_position = nil, nil
    d.restart_ack, d.ended_signal, d.started_signal = nil, nil, nil
end
local function acquire(d, p)
    local owner = owners[d.parent_uuid]
    if owner and owner ~= d then
        d.duplicate = true
        log(d, '同じソースにこのフィルタを重複適用できません。')
        return false
    end
    d.duplicate = false
    cancel_restore(d.parent_uuid)
    d.has_audio = bit.band(obs.obs_source_get_output_flags(p), obs.OBS_SOURCE_AUDIO) ~= 0
    local saved = d.saved
    if saved.owned and saved.parent == d.parent_uuid
            and saved.filter == obs.obs_source_get_uuid(d.context) then
        d.original_muted = saved.muted
    else
        d.original_muted = obs.obs_source_muted(p)
    end
    d.saved.owned = false
    d.owns, d.control_enabled = true, true
    owners[d.parent_uuid] = d
    remember(d, true)
    waiting(d, true)
    mute(d, p, true)
    if d.media then obs.obs_source_media_stop(p) end
    return true
end
local function end_event(d, p, failed)
    if failed then
        obs.obs_source_media_stop(p)
        log(d, failed)
    end
    mute(d, p, true)
    waiting(d, false)
end
local function start_event(d, p)
    apply_pending(d)
    d.generation = d.generation + 1
    d.state, d.elapsed, d.alpha, d.watchdog = 'STARTING', 0, 0, 0
    d.ready, d.restart_ack, d.ended_signal = false, nil, nil
    if d.media then
        d.request_pending = true
        d.before_restart = obs.obs_source_media_get_time(p)
        local before_state = obs.obs_source_media_get_state(p)
        d.before_restart_active = before_state == obs.OBS_MEDIA_STATE_PLAYING
            or before_state == obs.OBS_MEDIA_STATE_OPENING
            or before_state == obs.OBS_MEDIA_STATE_BUFFERING
            or before_state == obs.OBS_MEDIA_STATE_PAUSED
        d.restart_observed_position = d.before_restart
        d.rewind_position, d.last_position = nil, nil
        mute(d, p, true)
        obs.obs_source_media_restart(p)
        obs.obs_source_media_play_pause(p, false)
    else
        d.total = d.cfg.duration + (d.cfg.include and 0
            or d.cfg.start_duration + d.cfg.end_duration)
        d.alpha, d.state, d.start_progress, d.end_progress = envelope(0, d.total, d.cfg)
    end
end
local function persistent_tick(d, p, seconds)
    d.elapsed = d.elapsed + seconds
    if d.elapsed + 1e-9 >= d.total then
        local overshoot = math.max(0, d.elapsed - d.total)
        end_event(d, p)
        d.wait_left = math.max(0, d.wait_left - overshoot)
        return
    end
    d.alpha, d.state, d.start_progress, d.end_progress = envelope(d.elapsed, d.total, d.cfg)
end
local function media_tick(d, p, seconds)
    local state = obs.obs_source_media_get_state(p)
    local position = tonumber(obs.obs_source_media_get_time(p))
    local duration = tonumber(obs.obs_source_media_get_duration(p))
    if not finite(position) or position < 0 then position = 0 end
    local acknowledged = d.restart_ack == d.generation
    if acknowledged and state == obs.OBS_MEDIA_STATE_ENDED then
        end_event(d, p)
        return
    end
    if not d.ready then
        d.watchdog = d.watchdog + seconds
        -- Restart/started signals only confirm command dispatch. Keep the
        -- filter hidden until the reported playhead has both entered the new
        -- generation and advanced within it. A low stale PLAYING position can
        -- otherwise be exposed for one frame before a delayed ENDED state.
        local started = d.started_signal == d.generation
        local advanced_after_rewind = false
        if acknowledged and started and state == obs.OBS_MEDIA_STATE_PLAYING then
            local observed = d.restart_observed_position or d.before_restart or position
            if d.rewind_position ~= nil then
                if position < d.rewind_position then
                    d.rewind_position = position
                elseif position > d.rewind_position then
                    advanced_after_rewind = true
                end
            elseif position <= 0 or position < observed
                    or (not d.before_restart_active and position <= 250 * d.speed) then
                d.rewind_position = position
            else
                d.restart_observed_position = math.max(observed, position)
            end
        end
        if advanced_after_rewind then
            d.ready, d.request_pending, d.watchdog = true, false, 0
            d.last_position = position
            log(d, '')
        elseif d.watchdog >= WATCHDOG then
            end_event(d, p, '10秒以内に再生開始を確認できませんでした。次の間隔後に再試行します。')
            return
        else return end
    end
    if state == obs.OBS_MEDIA_STATE_ERROR or state == obs.OBS_MEDIA_STATE_STOPPED then
        end_event(d, p, 'メディアが停止またはエラーになりました。次の間隔後に再試行します。')
        return
    end
    if d.last_position ~= nil and position < d.last_position then
        -- A non-looping Media Source can report the first frame as PLAYING
        -- immediately before its delayed ENDED notification. Treat a backward
        -- playhead jump as the end of this controlled generation so that the
        -- rewound frame never reaches video_render.
        end_event(d, p)
        return
    elseif position > (d.last_position or -1) then
        d.last_position, d.watchdog = position, 0
    else d.watchdog = d.watchdog + seconds end
    if d.watchdog >= WATCHDOG then
        end_event(d, p, '再生位置が10秒間進みませんでした。次の間隔後に再試行します。')
        return
    end
    local total = finite(duration) and duration > 0 and duration / 1000 / d.speed or nil
    d.elapsed = position / 1000 / d.speed
    d.alpha, d.state, d.start_progress, d.end_progress = envelope(d.elapsed, total, d.cfg)
    if d.state == 'VISIBLE' then d.state = 'PLAYING' end
    -- Once fully faded, remain hidden until actual ENDED (or watchdog failure).
    if total and d.elapsed >= total then
        d.alpha, d.state, d.end_progress = d.cfg.end_effect == FADE and 0 or 1, 'ENDING', 1
    end
end

local function update_instance(d, seconds)
    if d.destroyed or d.detached or exiting or unloading then return end
    local p = obs.obs_filter_get_parent(d.context)
    if not p then return end -- create/update may precede attachment
    attach(d, p)
    if not d.effect or not obs.obs_source_enabled(d.context) then
        release_control(d, p, true)
        d.alpha = 1
        return
    end
    local media, speed, file, err = inspect_parent(d, p)
    if d.owns and (d.media ~= media or d.speed ~= speed or d.file ~= file) then
        -- Parent media changes invalidate its timeline; never reuse old events.
        release_control(d, p, false)
    end
    d.media, d.speed, d.file = media, speed, file
    if not d.owns and not acquire(d, p) then return end
    if err ~= '' then
        if not d.invalid and media then obs.obs_source_media_stop(p) end
        d.invalid, d.alpha = true, 0
        mute(d, p, true)
        log(d, err)
        return
    elseif d.invalid then
        d.invalid = false
        log(d, '')
        waiting(d, true)
    end
    local active = obs.obs_source_active(p)
    if not active then
        if d.media and d.state ~= 'WAITING' and not d.paused_by_us then
            local state = obs.obs_source_media_get_state(p)
            if state ~= obs.OBS_MEDIA_STATE_ENDED and state ~= obs.OBS_MEDIA_STATE_STOPPED then
                obs.obs_source_media_play_pause(p, true)
                d.paused_by_us = true
            end
        end
        d.active = false
        mute(d, p, true)
        return
    end
    if d.paused_by_us then
        obs.obs_source_media_play_pause(p, false)
        d.paused_by_us = false
        d.active = true
        return -- do not charge inactive elapsed time to the resumed event
    end
    d.active = true
    seconds = finite(seconds) and math.max(0, seconds) or 0
    if d.state == 'WAITING' then
        -- Reassert ownership if OBS auto-started after editing parent settings.
        if d.media then
            local state = obs.obs_source_media_get_state(p)
            if state == obs.OBS_MEDIA_STATE_PLAYING and not d.wait_stop_sent then
                obs.obs_source_media_stop(p)
                d.wait_stop_sent = true
            elseif state ~= obs.OBS_MEDIA_STATE_PLAYING then d.wait_stop_sent = false end
        end
        d.wait_left = d.wait_left - seconds
        if d.wait_left <= 1e-9 then
            local remainder = math.max(0, -d.wait_left)
            start_event(d, p)
            if not d.media then persistent_tick(d, p, remainder) end
        end
    elseif d.media then media_tick(d, p, seconds)
    else
        persistent_tick(d, p, seconds)
        -- A zero fixed interval has no waiting frame to render. Start the next
        -- Persistent event once, but do not advance it again in this tick.
        if d.state == 'WAITING' and not d.cfg.random and d.cfg.interval <= 1e-9 then
            start_event(d, p)
        end
    end
    local boundary_hidden = (d.state == 'STARTING'
            and (d.cfg.start_effect == PEEK or d.cfg.start_effect == WIPE
                or (d.cfg.start_effect == ZOOM and d.cfg.start_zoom_scale == 0))
            and d.start_progress <= 0)
        or (d.state == 'ENDING' and (d.cfg.end_effect == PEEK or d.cfg.end_effect == WIPE
                or (d.cfg.end_effect == ZOOM and d.cfg.end_zoom_scale == 0))
            and d.end_progress >= 1)
    mute(d, p, d.alpha <= 0 or boundary_hidden or (d.media and not d.ready))
end

local info = {id = ID, type = obs.OBS_SOURCE_TYPE_FILTER, output_flags = obs.OBS_SOURCE_VIDEO}
info.get_name = function() return TITLE end
info.get_defaults = function(s)
    for k, v in pairs({interval = 30, random_min = 20, random_max = 60,
        display_duration = 5, start_duration = 0.5, end_duration = 0.5,
        start_zoom_percent = 50, end_zoom_percent = 50,
        start_zoom_normal_percent = 50, end_zoom_normal_percent = 50,
        start_softness = 0, end_softness = 0}) do
        obs.obs_data_set_default_double(s, k, v)
    end
    for k, v in pairs({interval_mode = 0, first_display = 0, duration_mode = 0,
        start_effect = 1, end_effect = 1, start_direction = 2, end_direction = 6,
        start_angle = 0, end_angle = 0, start_zoom_anchor = 4, end_zoom_anchor = 4,
        start_easing = LINEAR, end_easing = LINEAR}) do
        obs.obs_data_set_default_int(s, k, v)
    end
    obs.obs_data_set_default_bool(s, 'start_zoom_high_mode', false)
    obs.obs_data_set_default_bool(s, 'end_zoom_high_mode', false)
end
local function initialize_zoom_ui(settings)
    for _, prefix in ipairs({'start', 'end'}) do
        local percent_key = prefix .. '_zoom_percent'
        local normal_key = prefix .. '_zoom_normal_percent'
        local mode_key = prefix .. '_zoom_high_mode'
        local percent = obs.obs_data_get_double(settings, percent_key)
        if not finite(percent) then percent = 50 end
        percent = clamp(percent, 0, ZOOM_UI_MAX)
        if not obs.obs_data_has_user_value(settings, mode_key) then
            obs.obs_data_set_bool(settings, mode_key, percent > 500)
        end
        obs.obs_data_set_double(settings, normal_key, clamp(percent, 0, 500))
        obs.obs_data_set_double(settings, percent_key, percent)
        obs.obs_data_unset_user_value(settings, percent_key .. '_slider')
    end
end
info.create = function(settings, source)
    initialize_zoom_ui(settings)
    serial = serial + 1
    local seed = (os.time() + serial * 104729 + math.floor(os.clock() * 1000000)) % 2147483646 + 1
    local d = {context = source, cfg = config(settings), state = 'WAITING', alpha = 0,
        wait_left = 0, seed = seed, generation = 0, notice = '',
        saved = {owned = obs.obs_data_get_bool(settings, '_ase_owned'),
            muted = obs.obs_data_get_bool(settings, '_ase_original_muted'),
            parent = obs.obs_data_get_string(settings, '_ase_parent_uuid'),
            filter = obs.obs_data_get_string(settings, '_ase_filter_uuid')},
    }
    obs.obs_enter_graphics()
    d.effect = obs.gs_effect_create(EFFECT, 'ambient-source-events.effect', nil)
    if d.effect then
        d.opacity_param = obs.gs_effect_get_param_by_name(d.effect, 'opacity')
        d.offset_x_param = obs.gs_effect_get_param_by_name(d.effect, 'offset_x')
        d.offset_y_param = obs.gs_effect_get_param_by_name(d.effect, 'offset_y')
        d.wipe_x_param = obs.gs_effect_get_param_by_name(d.effect, 'wipe_x')
        d.wipe_y_param = obs.gs_effect_get_param_by_name(d.effect, 'wipe_y')
        d.wipe_progress_param = obs.gs_effect_get_param_by_name(d.effect, 'wipe_progress')
        d.wipe_mode_param = obs.gs_effect_get_param_by_name(d.effect, 'wipe_mode')
        d.wipe_softness_param = obs.gs_effect_get_param_by_name(d.effect, 'wipe_softness')
        d.zoom_visible_param = obs.gs_effect_get_param_by_name(d.effect, 'zoom_visible')
    end
    obs.obs_leave_graphics()
    if not d.effect then
        d.alpha, d.notice = 1, 'シェーダーを作成できませんでした。通常表示へ戻します。'
        obs.script_log(obs.LOG_ERROR, TITLE .. ': ' .. d.notice)
    end
    d.enable_callback = function(cd)
        if not obs.calldata_bool(cd, 'enabled') then
            with_parent(d, function(p) release_control(d, p, true) end)
        end
    end
    d.destroy_callback = function()
        -- Normal source destruction has a valid scripting context here.
        with_parent(d, function(p) disconnect(d, p) end)
        local h = obs.obs_source_get_signal_handler(source)
        obs.signal_handler_disconnect(h, 'enable', d.enable_callback)
        obs.signal_handler_disconnect(h, 'destroy', d.destroy_callback)
        d.self_disconnected = true
    end
    d.self_weak = obs.obs_source_get_weak_source(source)
    obs.signal_handler_connect(obs.obs_source_get_signal_handler(source), 'enable', d.enable_callback)
    obs.signal_handler_connect(obs.obs_source_get_signal_handler(source), 'destroy', d.destroy_callback)
    instances[d] = true
    return d
end
info.update = function(d, settings) d.pending_cfg = config(settings) end
info.video_tick = update_instance
info.activate = function(d) d.activity_changed = true end
info.deactivate = function(d)
    -- Pause promptly; video_tick remains the sole owner of event-time changes.
    with_parent(d, function(p)
        if d.owns and d.media and d.state ~= 'WAITING' and not d.paused_by_us then
            local s = obs.obs_source_media_get_state(p)
            if s ~= obs.OBS_MEDIA_STATE_ENDED and s ~= obs.OBS_MEDIA_STATE_STOPPED then
                obs.obs_source_media_play_pause(p, true)
                d.paused_by_us = true
            end
        end
        mute(d, p, true)
    end)
    d.active = false
end
info.video_render = function(d)
    if d.destroyed then return end
    if not d.effect or d.duplicate or not obs.obs_source_enabled(d.context) then
        obs.obs_source_skip_video_filter(d.context)
        return
    end
    -- Before the first tick (also immediately after re-enable), ownership is
    -- not acquired yet. Keep the initial frame hidden without advancing state.
    local alpha = (not d.owns or d.active == false) and 0 or d.alpha
    if obs.obs_source_process_filter_begin(d.context, obs.GS_RGBA, obs.OBS_NO_DIRECT_RENDERING) then
        local target = obs.obs_filter_get_target(d.context)
        local width = target and obs.obs_source_get_base_width(target) or 0
        local height = target and obs.obs_source_get_base_height(target) or 0
        local offset_x, offset_y = peek_offset(d, width, height)
        local wipe_x, wipe_y, wipe_progress, wipe_mode, wipe_softness =
            wipe_parameters(d, width, height)
        local scale, translate_x, translate_y = zoom_transform(d, width, height)
        obs.gs_effect_set_float(d.opacity_param, clamp(alpha, 0, 1))
        obs.gs_effect_set_float(d.offset_x_param, offset_x)
        obs.gs_effect_set_float(d.offset_y_param, offset_y)
        obs.gs_effect_set_float(d.wipe_x_param, wipe_x)
        obs.gs_effect_set_float(d.wipe_y_param, wipe_y)
        obs.gs_effect_set_float(d.wipe_progress_param, wipe_progress)
        obs.gs_effect_set_float(d.wipe_mode_param, wipe_mode)
        obs.gs_effect_set_float(d.wipe_softness_param, wipe_softness)
        obs.gs_effect_set_float(d.zoom_visible_param, scale > 0 and 1 or 0)
        obs.gs_blend_state_push()
        obs.gs_blend_function(obs.GS_BLEND_ONE, obs.GS_BLEND_INVSRCALPHA)
        obs.gs_matrix_push()
        if scale > 0 then
            obs.gs_matrix_translate3f(translate_x, translate_y, 0)
            obs.gs_matrix_scale3f(scale, scale, 1)
        end
        obs.obs_source_process_filter_end(d.context, d.effect, 0, 0)
        obs.gs_matrix_pop()
        obs.gs_blend_state_pop()
    end
end
info.get_width = function(d)
    local t = obs.obs_filter_get_target(d.context)
    return t and obs.obs_source_get_base_width(t) or 0
end
info.get_height = function(d)
    local t = obs.obs_filter_get_target(d.context)
    return t and obs.obs_source_get_base_height(t) or 0
end
info.save = function(d, settings)
    obs.obs_data_set_bool(settings, '_ase_owned', d.owns or false)
    obs.obs_data_set_bool(settings, '_ase_original_muted', d.original_muted or false)
    obs.obs_data_set_string(settings, '_ase_parent_uuid', d.parent_uuid or '')
    obs.obs_data_set_string(settings, '_ase_filter_uuid', obs.obs_source_get_uuid(d.context))
end
info.destroy = function(d)
    if d.destroyed then return end
    -- OBS 32.0.4 calls this during undef_lua_script_sources without setting
    -- current_lua_script. Signal disconnect/log/timer APIs would dereference NULL.
    -- Keep live handlers referenced; disconnect in script_tick/script_unload.
    detach(d, not exiting, true)
    if not d.self_disconnected then
        local self = obs.obs_weak_source_get_source(d.self_weak)
        if self then
            disconnect_jobs[#disconnect_jobs + 1] = {source = self,
                connections = {enable = d.enable_callback, destroy = d.destroy_callback}}
        end
    end
    obs.obs_weak_source_release(d.self_weak)
    d.destroyed = true
    instances[d] = nil
    if d.effect then
        obs.obs_enter_graphics(); obs.gs_effect_destroy(d.effect); obs.obs_leave_graphics()
        d.effect = nil
    end
end

local function add_list(props, key, label, entries)
    local p = obs.obs_properties_add_list(props, key, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    for i, text in ipairs(entries) do obs.obs_property_list_add_int(p, text, i - 1) end
    return p
end
local function add_seconds(props, key, label, minimum)
    local p = obs.obs_properties_add_float(props, key, label, minimum or 0, LIMIT, 0.01)
    obs.obs_property_float_set_suffix(p, ' 秒')
    return p
end
local layout
local function zoom_normal_changed(_, property, settings)
    local normal_key = obs.obs_property_name(property)
    local percent_key = normal_key:gsub('_normal_percent$', '_percent')
    local percent = clamp(obs.obs_data_get_double(settings, normal_key), 0, 500)
    obs.obs_data_set_double(settings, percent_key, percent)
    return false
end
local function zoom_mode_changed(props, property, settings)
    local mode_key = obs.obs_property_name(property)
    local prefix = mode_key:gsub('_zoom_high_mode$', '')
    local percent_key = prefix .. '_zoom_percent'
    local normal_key = prefix .. '_zoom_normal_percent'
    local percent = obs.obs_data_get_double(settings, percent_key)
    if not finite(percent) then percent = 50 end
    if obs.obs_data_get_bool(settings, mode_key) then
        obs.obs_data_set_double(settings, normal_key, clamp(percent, 0, 500))
    else
        percent = clamp(percent, 0, 500)
        obs.obs_data_set_double(settings, percent_key, percent)
        obs.obs_data_set_double(settings, normal_key, percent)
    end
    layout(props, nil, settings)
    return true
end
layout = function(props, _, settings)
    local random = obs.obs_data_get_int(settings, 'interval_mode') == 1
    obs.obs_property_set_visible(obs.obs_properties_get(props, 'interval'), not random)
    obs.obs_property_set_visible(obs.obs_properties_get(props, 'random_min'), random)
    obs.obs_property_set_visible(obs.obs_properties_get(props, 'random_max'), random)
    for _, prefix in ipairs({'start', 'end'}) do
        local selected = obs.obs_data_get_int(settings, prefix .. '_effect')
        local directional = selected == PEEK or selected == WIPE
        local wipe = selected == WIPE
        local zoom = selected == ZOOM
        obs.obs_property_set_visible(obs.obs_properties_get(props, prefix .. '_duration'), selected ~= NONE)
        obs.obs_property_set_visible(obs.obs_properties_get(props, prefix .. '_easing'), selected ~= NONE)
        obs.obs_property_set_visible(obs.obs_properties_get(props, prefix .. '_direction'), directional)
        obs.obs_property_set_visible(obs.obs_properties_get(props, prefix .. '_angle'), directional
            and obs.obs_data_get_int(settings, prefix .. '_direction') == 8)
        obs.obs_property_set_visible(obs.obs_properties_get(props, prefix .. '_softness'), wipe)
        obs.obs_property_set_visible(obs.obs_properties_get(props, prefix .. '_zoom_anchor'), zoom)
        local high = obs.obs_data_get_bool(settings, prefix .. '_zoom_high_mode')
        obs.obs_property_set_visible(obs.obs_properties_get(props,
            prefix .. '_zoom_normal_percent'), zoom and not high)
        obs.obs_property_set_visible(obs.obs_properties_get(props,
            prefix .. '_zoom_percent'), zoom and high)
        obs.obs_property_set_visible(obs.obs_properties_get(props,
            prefix .. '_zoom_high_mode'), zoom)
    end
    return true
end
info.get_properties = function(d)
    local props = obs.obs_properties_create()
    local group = obs.obs_properties_create()
    local mode = add_list(group, 'interval_mode', '間隔モード', {'固定間隔', 'ランダム間隔'})
    obs.obs_property_set_modified_callback(mode, layout)
    add_seconds(group, 'interval', '固定間隔')
    add_seconds(group, 'random_min', 'ランダム最小')
    add_seconds(group, 'random_max', 'ランダム最大')
    obs.obs_properties_add_group(props, 'timing', 'タイミング', obs.OBS_GROUP_NORMAL, group)
    add_list(props, 'first_display', '初回表示', {'すぐに表示', '最初の待機時間を経過してから表示'})
    group = obs.obs_properties_create()
    add_seconds(group, 'display_duration', '表示時間', 0.01)
    add_list(group, 'duration_mode', '表示時間の数え方', {
        '表示時間の中に開始・終了エフェクトを含める', '表示時間とは別に開始・終了エフェクトを追加する'})
    local display = obs.obs_properties_add_group(props, 'display', '表示', obs.OBS_GROUP_NORMAL, group)
    local media = d and d.media or false
    if d and not d.parent then
        local p = obs.obs_filter_get_parent(d.context)
        if p then media = inspect_parent(d, p) end
    end
    obs.obs_property_set_visible(display, not media)
    for _, entry in ipairs({{'start', '開始エフェクト'}, {'end', '終了エフェクト'}}) do
        group = obs.obs_properties_create()
        local effect = add_list(group, entry[1] .. '_effect', '種類', {'なし', 'フェード', 'Peek', 'Wipe', 'Zoom'})
        obs.obs_property_set_modified_callback(effect, layout)
        add_seconds(group, entry[1] .. '_duration', '時間')
        add_list(group, entry[1] .. '_easing', '変化のしかた', {
            '一定', 'ゆっくり始まる', 'ゆっくり終わる',
            'ゆっくり始まり、ゆっくり終わる'})
        local direction_property = add_list(group, entry[1] .. '_direction', '方向', {
            '↑ 上へ', '↗ 右上へ', '→ 右へ', '↘ 右下へ',
            '↓ 下へ', '↙ 左下へ', '← 左へ', '↖ 左上へ', '任意角度'})
        obs.obs_property_set_modified_callback(direction_property, layout)
        local angle_property = obs.obs_properties_add_int(group, entry[1] .. '_angle',
            '角度', 0, 359, 1)
        obs.obs_property_int_set_suffix(angle_property, '°')
        local softness_property = obs.obs_properties_add_float(group,
            entry[1] .. '_softness', 'Softness', 0, 100, 1)
        obs.obs_property_float_set_suffix(softness_property, ' %')
        local zoom_anchor_property = obs.obs_properties_add_list(group,
            entry[1] .. '_zoom_anchor', 'ズーム基準点',
            obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
        for _, anchor in ipairs({
                {'● 中央', 4}, {'↑ 上', 1}, {'↗ 右上', 2},
                {'→ 右', 5}, {'↘ 右下', 8}, {'↓ 下', 7},
                {'↙ 左下', 6}, {'← 左', 3}, {'↖ 左上', 0}}) do
            obs.obs_property_list_add_int(zoom_anchor_property, anchor[1], anchor[2])
        end
        local zoom_normal = obs.obs_properties_add_float_slider(group,
            entry[1] .. '_zoom_normal_percent', '倍率', 0, 500, 0.1)
        obs.obs_property_float_set_suffix(zoom_normal, ' %')
        obs.obs_property_set_modified_callback(zoom_normal, zoom_normal_changed)
        local zoom_percent = obs.obs_properties_add_float(group, entry[1] .. '_zoom_percent',
            '倍率', 0, ZOOM_UI_MAX, 10.0)
        obs.obs_property_float_set_suffix(zoom_percent, ' %')
        local zoom_mode = obs.obs_properties_add_bool(group, entry[1] .. '_zoom_high_mode',
            '500%を超える倍率を設定')
        obs.obs_property_set_modified_callback(zoom_mode, zoom_mode_changed)
        obs.obs_properties_add_group(props, entry[1], entry[2], obs.OBS_GROUP_NORMAL, group)
    end
    local message = d and d.notice or ''
    if media then message = message .. (message ~= '' and '\n' or '') ..
        'Media Source: 繰り返し・アクティブ化時の再スタート・非アクティブ時のファイル閉鎖をOFFにしてください。' end
    message = message .. '\n非表示中は対象ソースをミュートします。同じソースの全参照先に作用します。' ..
        '\nZoomは開発者環境で5,000%まで動作確認済みです。より高い倍率も設定できますが、環境やソースによっては正常に描画できない場合があります。'
    obs.obs_properties_add_text(props, 'requirements', message, obs.OBS_TEXT_INFO)
    if d then
        local s = obs.obs_source_get_settings(d.context)
        layout(props, nil, s)
        obs.obs_data_release(s)
    end
    return props
end

-- Only deferred normal-playback restoration runs here; no event timers.
function script_tick()
    flush_disconnects()
    for uuid, job in pairs(restore_jobs) do
        job.frames = job.frames + 1
        local p = obs.obs_weak_source_get_source(job.parent)
        local done = not p or exiting or owners[uuid] ~= nil
        if p and not done and job.frames > 1 then done = normal_playback(p) end
        if p then obs.obs_source_release(p) end
        if done then cancel_restore(uuid) end
    end
end
local function frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_EXIT or event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN
            or event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP then
        exiting = true
        for d in pairs(instances) do with_parent(d, function(p) release_control(d, p, false) end) end
        for uuid in pairs(restore_jobs) do cancel_restore(uuid) end
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then exiting = false end
end
function script_description()
    return 'ソース定期表示（Ambient Source Events）0.7.0\n' ..
        '各ソースの「フィルタ → ＋ → ソース定期表示」から追加してください。\n' ..
        '映像の定期表示・フェード・Peek・Wipe・Zoomと非表示中の消音。対応条件はREADME.mdをご確認ください。'
end
function script_load()
    exiting, unloading = false, false
    obs.obs_register_source(info)
    obs.obs_frontend_add_event_callback(frontend_event)
end
function script_unload()
    unloading = true
    flush_disconnects()
    for d in pairs(instances) do with_parent(d, function(p) release_control(d, p, not exiting) end) end
    -- Unload cannot leave callbacks behind. Perform available restorations now.
    for uuid, job in pairs(restore_jobs) do
        local p = obs.obs_weak_source_get_source(job.parent)
        if p then
            if not exiting then normal_playback(p) end
            obs.obs_source_release(p)
        end
        cancel_restore(uuid)
    end
    obs.obs_frontend_remove_event_callback(frontend_event)
end
