--
-- OBS Zoom To Mouse - Zone Based Movement
-- Script Lua para mover una fuente basándose en la zona del mouse
-- Con movimiento suave, zoom opcional y hotkey toggle
--

local obs = obslua
local ffi = require("ffi")

-- ============================================================================
-- CONFIGURACIÓN FFI PARA OBTENER POSICIÓN DEL MOUSE (WINDOWS)
-- ============================================================================
ffi.cdef([[
    typedef int BOOL;
    typedef struct {
        long x;
        long y;
    } POINT, *LPPOINT;
    BOOL GetCursorPos(LPPOINT);
    int GetSystemMetrics(int);
]])

local win_point = ffi.new("POINT[1]")

-- ============================================================================
-- VARIABLES GLOBALES
-- ============================================================================

-- Configuración del usuario
local settings = {
    debug_enabled = true,
    source_name = "",
    zone_mode = "3zones",       -- "3zones", "5zones", "7zones", o "6zones"
    
    -- 3 Zonas
    left_percent = 33.33,
    center_percent = 33.33,
    right_percent = 33.33,
    
    -- 5 Zonas
    z5_left = 20.0,
    z5_lc = 20.0,
    z5_center = 20.0,
    z5_rc = 20.0,
    z5_right = 20.0,
    
    -- 7 Zonas
    z7_left = 14.28,
    z7_lc1 = 14.28,
    z7_lc2 = 14.28,
    z7_center = 14.28,
    z7_rc1 = 14.28,
    z7_rc2 = 14.28,
    z7_right = 14.32, -- Ajustado para sumar 100
    
    move_x = true,
    move_y = false,
    -- Desplazamientos individuales por dirección
    offset_x_left = 100,
    offset_x_right = 100,
    offset_y_up = 100,
    offset_y_down = 100,
    transition_speed = 300,     -- milisegundos
    zoom_enabled = false,
    zoom_factor = 1.5,
    screen_width = 1920,
    screen_height = 1080,
    -- Posición central manual
    center_x = 0,
    center_y = 0,
    use_manual_center = false,
}

-- Variable para guardar settings_data global para el botón
local script_settings = nil

-- Estado del plugin
local state = {
    enabled = false,
    hotkey_id = nil,
    source = nil,
    sceneitem = nil,
    original_pos = { x = 0, y = 0 },
    original_scale = { x = 1, y = 1 },
    source_width = 0,
    source_height = 0,
    start_pos = { x = 0, y = 0 },
    start_scale = { x = 1, y = 1 },
    current_pos = { x = 0, y = 0 },
    current_scale = { x = 1, y = 1 },
    target_pos = { x = 0, y = 0 },
    target_scale = { x = 1, y = 1 },
    current_zone = { h = "center", v = "center" },
    animation_progress = 1.0,
    is_animating = false,
}

-- ============================================================================
-- UTILIDADES
-- ============================================================================

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function ease_out_cubic(t)
    return 1 - math.pow(1 - t, 3)
end

local function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

local function log(msg)
    if settings.debug_enabled then
        obs.script_log(obs.OBS_LOG_INFO, "[ZoomToMouse] " .. msg)
    end
end

-- ============================================================================
-- OBTENER POSICIÓN DEL MOUSE
-- ============================================================================

local function get_mouse_pos()
    if ffi.C.GetCursorPos(win_point) ~= 0 then
        return { x = win_point[0].x, y = win_point[0].y }
    end
    return { x = 0, y = 0 }
end

-- ============================================================================
-- CÁLCULO DE ZONAS
-- ============================================================================

local function get_horizontal_zone(mouse_x)
    local screen_w = settings.screen_width
    
    if settings.zone_mode == "5zones" then
        local b1 = screen_w * (settings.z5_left / 100)
        local b2 = b1 + screen_w * (settings.z5_lc / 100)
        local b3 = b2 + screen_w * (settings.z5_center / 100)
        local b4 = b3 + screen_w * (settings.z5_rc / 100)
        
        if mouse_x < b1 then return "left"
        elseif mouse_x < b2 then return "left_center"
        elseif mouse_x < b3 then return "center"
        elseif mouse_x < b4 then return "right_center"
        else return "right" end
        
    elseif settings.zone_mode == "7zones" then
        local b1 = screen_w * (settings.z7_left / 100)
        local b2 = b1 + screen_w * (settings.z7_lc1 / 100)
        local b3 = b2 + screen_w * (settings.z7_lc2 / 100)
        local b4 = b3 + screen_w * (settings.z7_center / 100)
        local b5 = b4 + screen_w * (settings.z7_rc1 / 100)
        local b6 = b5 + screen_w * (settings.z7_rc2 / 100)
        
        if mouse_x < b1 then return "left"
        elseif mouse_x < b2 then return "left_center1"
        elseif mouse_x < b3 then return "left_center2"
        elseif mouse_x < b4 then return "center"
        elseif mouse_x < b5 then return "right_center1"
        elseif mouse_x < b6 then return "right_center2"
        else return "right" end
        
    else
        -- 3zones y 6zones comparten la misma horizontal "left, center, right" basada en 3 porcentajes
        local left_boundary = screen_w * (settings.left_percent / 100)
        local center_boundary = left_boundary + screen_w * (settings.center_percent / 100)
        
        if mouse_x < left_boundary then
            return "left"
        elseif mouse_x < center_boundary then
            return "center"
        else
            return "right"
        end
    end
end

local function get_vertical_zone(mouse_y)
    local screen_h = settings.screen_height
    local half = screen_h / 2
    
    if mouse_y < half then
        return "top"
    else
        return "bottom"
    end
end

local function get_current_zone(mouse_pos)
    local zone = {
        h = get_horizontal_zone(mouse_pos.x),
        v = "center"
    }
    
    if settings.zone_mode == "6zones" then
        zone.v = get_vertical_zone(mouse_pos.y)
    end
    
    return zone
end

-- ============================================================================
-- CÁLCULO DE POSICIÓN OBJETIVO
-- ============================================================================

local function calculate_target_position(zone, mouse_pos)
    local target = {
        x = state.original_pos.x,
        y = state.original_pos.y
    }
    
    if settings.move_x then
        local ratio = 0.0 -- -1.0 a la izq, 1.0 a la der
        
        if settings.zone_mode == "5zones" then
            if zone.h == "left" then ratio = -1.0
            elseif zone.h == "left_center" then ratio = -0.5
            elseif zone.h == "center" then ratio = 0.0
            elseif zone.h == "right_center" then ratio = 0.5
            elseif zone.h == "right" then ratio = 1.0
            end
        elseif settings.zone_mode == "7zones" then
            if zone.h == "left" then ratio = -1.0
            elseif zone.h == "left_center1" then ratio = -0.66
            elseif zone.h == "left_center2" then ratio = -0.33
            elseif zone.h == "center" then ratio = 0.0
            elseif zone.h == "right_center1" then ratio = 0.33
            elseif zone.h == "right_center2" then ratio = 0.66
            elseif zone.h == "right" then ratio = 1.0
            end
        else -- 3zones o 6zones
            if zone.h == "left" then ratio = -1.0
            elseif zone.h == "right" then ratio = 1.0
            else ratio = 0.0
            end
        end
        
        -- OJO: Un ratio NEGATIVO (mouse a la izquierda) debe MOVER a la DERECHA
        if ratio < 0 then
            -- Mover a la derecha (offset_x_left) por la proporción abs(ratio)
            target.x = state.original_pos.x + (settings.offset_x_left * math.abs(ratio))
        elseif ratio > 0 then
            -- Mover a la izquierda (offset_x_right)
            target.x = state.original_pos.x - (settings.offset_x_right * ratio)
        end
    end
    
    if settings.move_y and settings.zone_mode == "6zones" then
        if zone.v == "top" then
            target.y = state.original_pos.y + settings.offset_y_up
        elseif zone.v == "bottom" then
            target.y = state.original_pos.y - settings.offset_y_down
        end
    end
    
    if settings.zoom_enabled and state.source_width > 0 and state.source_height > 0 then
        local size_increase_x = state.source_width * state.original_scale.x * (settings.zoom_factor - 1)
        local size_increase_y = state.source_height * state.original_scale.y * (settings.zoom_factor - 1)
        target.x = target.x - (size_increase_x / 2)
        target.y = target.y - (size_increase_y / 2)
    end
    
    return target
end

local function calculate_target_scale(mouse_pos)
    if not settings.zoom_enabled then
        return { x = state.original_scale.x, y = state.original_scale.y }
    end
    
    return {
        x = state.original_scale.x * settings.zoom_factor,
        y = state.original_scale.y * settings.zoom_factor
    }
end

-- ============================================================================
-- OBTENER SCENEITEM DE LA FUENTE
-- ============================================================================

local function get_sceneitem()
    if settings.source_name == "" then return nil end
    local source = obs.obs_get_source_by_name(settings.source_name)
    if source == nil then return nil end
    
    local current_scene = obs.obs_frontend_get_current_scene()
    if current_scene == nil then
        obs.obs_source_release(source)
        return nil
    end
    
    local scene = obs.obs_scene_from_source(current_scene)
    local sceneitem = obs.obs_scene_find_source(scene, settings.source_name)
    
    obs.obs_source_release(source)
    obs.obs_source_release(current_scene)
    
    return sceneitem
end

local function save_original_transform()
    local sceneitem = get_sceneitem()
    if sceneitem == nil then
        log("No se pudo encontrar la fuente: " .. settings.source_name)
        return false
    end
    
    local source = obs.obs_get_source_by_name(settings.source_name)
    if source ~= nil then
        state.source_width = obs.obs_source_get_width(source)
        state.source_height = obs.obs_source_get_height(source)
        obs.obs_source_release(source)
        log("Tamaño de fuente: " .. state.source_width .. "x" .. state.source_height)
    end
    
    local pos = obs.vec2()
    obs.obs_sceneitem_get_pos(sceneitem, pos)
    
    if settings.use_manual_center then
        state.original_pos.x = settings.center_x
        state.original_pos.y = settings.center_y
        log("Usando posición central manual: " .. settings.center_x .. ", " .. settings.center_y)
    else
        state.original_pos.x = pos.x
        state.original_pos.y = pos.y
        log("Usando posición actual: " .. pos.x .. ", " .. pos.y)
    end
    
    state.start_pos.x, state.start_pos.y = pos.x, pos.y
    state.current_pos.x, state.current_pos.y = pos.x, pos.y
    state.target_pos.x, state.target_pos.y = state.original_pos.x, state.original_pos.y
    
    local scale = obs.vec2()
    obs.obs_sceneitem_get_scale(sceneitem, scale)
    state.original_scale.x, state.original_scale.y = scale.x, scale.y
    state.start_scale.x, state.start_scale.y = scale.x, scale.y
    state.current_scale.x, state.current_scale.y = scale.x, scale.y
    state.target_scale.x, state.target_scale.y = scale.x, scale.y
    
    state.current_zone = { h = "none", v = "none" }
    state.animation_progress = 1.0
    state.is_animating = false
    
    return true
end

local function capture_center_position(props, prop)
    if settings.source_name == "" then
        log("Error: No hay fuente seleccionada")
        return false
    end
    
    local sceneitem = get_sceneitem()
    if sceneitem == nil then
        log("Error: No se pudo encontrar la fuente")
        return false
    end
    
    local pos = obs.vec2()
    obs.obs_sceneitem_get_pos(sceneitem, pos)
    
    settings.center_x = pos.x
    settings.center_y = pos.y
    
    if script_settings ~= nil then
        obs.obs_data_set_double(script_settings, "center_x", pos.x)
        obs.obs_data_set_double(script_settings, "center_y", pos.y)
    end
    
    log("Posición central capturada: " .. pos.x .. ", " .. pos.y)
    return true
end

local function restore_original_transform()
    local sceneitem = get_sceneitem()
    if sceneitem == nil then return end
    
    local pos = obs.vec2()
    pos.x = state.original_pos.x
    pos.y = state.original_pos.y
    obs.obs_sceneitem_set_pos(sceneitem, pos)
    
    local scale = obs.vec2()
    scale.x = state.original_scale.x
    scale.y = state.original_scale.y
    obs.obs_sceneitem_set_scale(sceneitem, scale)
    
    state.current_pos.x, state.current_pos.y = state.original_pos.x, state.original_pos.y
    state.current_scale.x, state.current_scale.y = state.original_scale.x, state.original_scale.y
    
    log("Transformación restaurada")
end

-- ============================================================================
-- LOOP PRINCIPAL DE ANIMACIÓN
-- ============================================================================

local last_time = 0
local FRAME_TIME = 16

local function animation_tick()
    if not state.enabled then return end
    
    local mouse_pos = get_mouse_pos()
    local new_zone = get_current_zone(mouse_pos)
    
    if new_zone.h ~= state.current_zone.h or new_zone.v ~= state.current_zone.v then
        state.start_pos.x, state.start_pos.y = state.current_pos.x, state.current_pos.y
        state.start_scale.x, state.start_scale.y = state.current_scale.x, state.current_scale.y
        
        state.current_zone = new_zone
        state.target_pos = calculate_target_position(new_zone, mouse_pos)
        state.target_scale = calculate_target_scale(mouse_pos)
        
        state.animation_progress = 0
        state.is_animating = true
        log("Cambio de zona: " .. new_zone.h .. " / " .. new_zone.v)
    end
    
    if state.is_animating then
        local progress_increment = FRAME_TIME / settings.transition_speed
        state.animation_progress = clamp(state.animation_progress + progress_increment, 0, 1)
        
        local eased_progress = ease_out_cubic(state.animation_progress)
        
        state.current_pos.x = lerp(state.start_pos.x, state.target_pos.x, eased_progress)
        state.current_pos.y = lerp(state.start_pos.y, state.target_pos.y, eased_progress)
        
        if settings.zoom_enabled then
            state.current_scale.x = lerp(state.start_scale.x, state.target_scale.x, eased_progress)
            state.current_scale.y = lerp(state.start_scale.y, state.target_scale.y, eased_progress)
        end
        
        local sceneitem = get_sceneitem()
        if sceneitem ~= nil then
            local pos = obs.vec2()
            pos.x = state.current_pos.x
            pos.y = state.current_pos.y
            obs.obs_sceneitem_set_pos(sceneitem, pos)
            
            if settings.zoom_enabled then
                local scale = obs.vec2()
                scale.x = state.current_scale.x
                scale.y = state.current_scale.y
                obs.obs_sceneitem_set_scale(sceneitem, scale)
            end
        end
        
        if state.animation_progress >= 1.0 then
            state.is_animating = false
        end
    end
end

-- ============================================================================
-- HOTKEY TOGGLE
-- ============================================================================

local function toggle_enabled(pressed)
    if not pressed then return end
    
    state.enabled = not state.enabled
    
    if state.enabled then
        log("Plugin ACTIVADO")
        if save_original_transform() then
            obs.timer_add(animation_tick, FRAME_TIME)
        else
            state.enabled = false
            log("Error: No se pudo guardar la transformación original")
        end
    else
        log("Plugin DESACTIVADO")
        obs.timer_remove(animation_tick)
        restore_original_transform()
    end
end

-- ============================================================================
-- PROPIEDADES DEL SCRIPT (UI)
-- ============================================================================

local function refresh_sources_list(props_arg, prop)
    if props_arg == nil then return true end
    
    local source_list = obs.obs_properties_get(props_arg, "source_name")
    if source_list ~= nil then
        obs.obs_property_list_clear(source_list)
        local sources = obs.obs_enum_sources()
        if sources ~= nil then
            for _, source in ipairs(sources) do
                local source_id = obs.obs_source_get_unversioned_id(source)
                -- Filtrar fuentes de audio estándar para mayor limpieza
                if source_id ~= "wasapi_input_capture" and source_id ~= "wasapi_output_capture" and source_id ~= "wasapi_process_output_capture" then
                    local name = obs.obs_source_get_name(source)
                    obs.obs_property_list_add_string(source_list, name, name)
                end
            end
            obs.source_list_release(sources)
        end
    end
    return true
end

-- Función de callback para cuando cambie la opción zone_mode
local function update_visibility(props, property, settings_data)
    local mode = obs.obs_data_get_string(settings_data, "zone_mode")
    
    -- Props de 3 zonas y 6 zonas (comparten horizontales)
    local p_lp = obs.obs_properties_get(props, "left_percent")
    local p_cp = obs.obs_properties_get(props, "center_percent")
    local p_rp = obs.obs_properties_get(props, "right_percent")
    local p_my = obs.obs_properties_get(props, "move_y")
    local p_oyu = obs.obs_properties_get(props, "offset_y_up")
    local p_oyd = obs.obs_properties_get(props, "offset_y_down")
    
    -- Props 5 zonas
    local p5_1 = obs.obs_properties_get(props, "z5_left")
    local p5_2 = obs.obs_properties_get(props, "z5_lc")
    local p5_3 = obs.obs_properties_get(props, "z5_center")
    local p5_4 = obs.obs_properties_get(props, "z5_rc")
    local p5_5 = obs.obs_properties_get(props, "z5_right")
    
    -- Props 7 zonas
    local p7_1 = obs.obs_properties_get(props, "z7_left")
    local p7_2 = obs.obs_properties_get(props, "z7_lc1")
    local p7_3 = obs.obs_properties_get(props, "z7_lc2")
    local p7_4 = obs.obs_properties_get(props, "z7_center")
    local p7_5 = obs.obs_properties_get(props, "z7_rc1")
    local p7_6 = obs.obs_properties_get(props, "z7_rc2")
    local p7_7 = obs.obs_properties_get(props, "z7_right")
    
    local is_3 = (mode == "3zones" or mode == "6zones")
    local is_5 = (mode == "5zones")
    local is_7 = (mode == "7zones")
    
    obs.obs_property_set_visible(p_lp, is_3)
    obs.obs_property_set_visible(p_cp, is_3)
    obs.obs_property_set_visible(p_rp, is_3)
    obs.obs_property_set_visible(p_my, mode == "6zones")
    obs.obs_property_set_visible(p_oyu, mode == "6zones")
    obs.obs_property_set_visible(p_oyd, mode == "6zones")
    
    obs.obs_property_set_visible(p5_1, is_5)
    obs.obs_property_set_visible(p5_2, is_5)
    obs.obs_property_set_visible(p5_3, is_5)
    obs.obs_property_set_visible(p5_4, is_5)
    obs.obs_property_set_visible(p5_5, is_5)
    
    obs.obs_property_set_visible(p7_1, is_7)
    obs.obs_property_set_visible(p7_2, is_7)
    obs.obs_property_set_visible(p7_3, is_7)
    obs.obs_property_set_visible(p7_4, is_7)
    obs.obs_property_set_visible(p7_5, is_7)
    obs.obs_property_set_visible(p7_6, is_7)
    obs.obs_property_set_visible(p7_7, is_7)
    
    return true
end

function script_properties()
    local props = obs.obs_properties_create()
    
    obs.obs_properties_add_text(props, "info", 
        "Zoom To Mouse - Zone Based Movement\n" ..
        "Activa con el hotkey configurado en Settings → Hotkeys",
        obs.OBS_TEXT_INFO)
    
    obs.obs_properties_add_bool(props, "debug_enabled", "Habilitar Logger de Debug (Mostrar en ventana Script)")

    local source_list = obs.obs_properties_add_list(props, "source_name", 
        "Fuente a mover", 
        obs.OBS_COMBO_TYPE_LIST, 
        obs.OBS_COMBO_FORMAT_STRING)
    
    obs.obs_properties_add_button(props, "refresh_sources", "Refrescar lista de fuentes", refresh_sources_list)

    refresh_sources_list(props, source_list)
    
    obs.obs_properties_add_int(props, "screen_width", "Ancho de pantalla", 640, 7680, 1)
    obs.obs_properties_add_int(props, "screen_height", "Alto de pantalla", 480, 4320, 1)
    
    local zone_mode = obs.obs_properties_add_list(props, "zone_mode",
        "Modo de zonas",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(zone_mode, "3 Zonas (Izq/Centro/Der)", "3zones")
    obs.obs_property_list_add_string(zone_mode, "5 Zonas (I/IC/C/DC/D)", "5zones")
    obs.obs_property_list_add_string(zone_mode, "7 Zonas (I/IC1/IC2/C/DC1/DC2/D)", "7zones")
    obs.obs_property_list_add_string(zone_mode, "6 Zonas (3x2 cuadrícula)", "6zones")
    
    -- 3 Zonas Props
    obs.obs_properties_add_float_slider(props, "left_percent", "% 3 Zonas: Izquierda", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "center_percent", "% 3 Zonas: Centro", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "right_percent", "% 3 Zonas: Derecha", 0, 100, 0.1)
    
    -- 5 Zonas Props
    obs.obs_properties_add_float_slider(props, "z5_left", "% 5 Zonas: Izquierda", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z5_lc", "% 5 Zonas: Izq-Centro", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z5_center", "% 5 Zonas: Centro", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z5_rc", "% 5 Zonas: Der-Centro", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z5_right", "% 5 Zonas: Derecha", 0, 100, 0.1)
    
    -- 7 Zonas Props
    obs.obs_properties_add_float_slider(props, "z7_left", "% 7 Zonas: Izquierda", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z7_lc1", "% 7 Zonas: Izq-Centro 1", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z7_lc2", "% 7 Zonas: Izq-Centro 2", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z7_center", "% 7 Zonas: Centro", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z7_rc1", "% 7 Zonas: Der-Centro 1", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z7_rc2", "% 7 Zonas: Der-Centro 2", 0, 100, 0.1)
    obs.obs_properties_add_float_slider(props, "z7_right", "% 7 Zonas: Derecha", 0, 100, 0.1)
    
    obs.obs_properties_add_bool(props, "move_x", "Mover en eje X")
    obs.obs_properties_add_bool(props, "move_y", "Mover en eje Y (solo modo 6 zonas)")
    
    obs.obs_properties_add_int(props, "offset_x_left", "Desplazamiento MAX cuando mouse IZQUIERDA (px)", 0, 100000, 10)
    obs.obs_properties_add_int(props, "offset_x_right", "Desplazamiento MAX cuando mouse DERECHA (px)", 0, 100000, 10)
    obs.obs_properties_add_int(props, "offset_y_up", "Desplazamiento MAX cuando mouse ARRIBA (px)", 0, 100000, 10)
    obs.obs_properties_add_int(props, "offset_y_down", "Desplazamiento MAX cuando mouse ABAJO (px)", 0, 100000, 10)
    
    obs.obs_properties_add_int(props, "transition_speed", "Velocidad transición (ms)", 50, 2000, 50)
    
    obs.obs_properties_add_bool(props, "zoom_enabled", "Habilitar Zoom")
    obs.obs_properties_add_float_slider(props, "zoom_factor", "Factor de Zoom", 1.0, 4.0, 0.1)
    
    obs.obs_properties_add_text(props, "separator", "--- POSICIÓN CENTRAL ---", obs.OBS_TEXT_INFO)
    
    obs.obs_properties_add_bool(props, "use_manual_center", "Usar posición central manual")
    
    obs.obs_properties_add_float(props, "center_x", "Posición X central", -100000, 100000, 1)
    obs.obs_properties_add_float(props, "center_y", "Posición Y central", -100000, 100000, 1)
    
    obs.obs_properties_add_button(props, "capture_center", "Capturar posición actual como centro", capture_center_position)
    
    obs.obs_property_set_modified_callback(zone_mode, update_visibility)
    
    -- Fuerza la actualización por si el callback en OBS versiones nuevas/viejas no lo dispara en el registro
    if script_settings ~= nil then
        update_visibility(props, zone_mode, script_settings)
    end
    
    return props
end

function script_defaults(settings_data)
    obs.obs_data_set_default_bool(settings_data, "debug_enabled", true)
    obs.obs_data_set_default_string(settings_data, "source_name", "")
    obs.obs_data_set_default_int(settings_data, "screen_width", 1920)
    obs.obs_data_set_default_int(settings_data, "screen_height", 1080)
    obs.obs_data_set_default_string(settings_data, "zone_mode", "3zones")
    
    obs.obs_data_set_default_double(settings_data, "left_percent", 33.33)
    obs.obs_data_set_default_double(settings_data, "center_percent", 33.33)
    obs.obs_data_set_default_double(settings_data, "right_percent", 33.33)
    
    obs.obs_data_set_default_double(settings_data, "z5_left", 20.0)
    obs.obs_data_set_default_double(settings_data, "z5_lc", 20.0)
    obs.obs_data_set_default_double(settings_data, "z5_center", 20.0)
    obs.obs_data_set_default_double(settings_data, "z5_rc", 20.0)
    obs.obs_data_set_default_double(settings_data, "z5_right", 20.0)
    
    obs.obs_data_set_default_double(settings_data, "z7_left", 14.28)
    obs.obs_data_set_default_double(settings_data, "z7_lc1", 14.28)
    obs.obs_data_set_default_double(settings_data, "z7_lc2", 14.28)
    obs.obs_data_set_default_double(settings_data, "z7_center", 14.28)
    obs.obs_data_set_default_double(settings_data, "z7_rc1", 14.28)
    obs.obs_data_set_default_double(settings_data, "z7_rc2", 14.28)
    obs.obs_data_set_default_double(settings_data, "z7_right", 14.32)
    
    obs.obs_data_set_default_bool(settings_data, "move_x", true)
    obs.obs_data_set_default_bool(settings_data, "move_y", false)
    obs.obs_data_set_default_int(settings_data, "offset_x_left", 100)
    obs.obs_data_set_default_int(settings_data, "offset_x_right", 100)
    obs.obs_data_set_default_int(settings_data, "offset_y_up", 100)
    obs.obs_data_set_default_int(settings_data, "offset_y_down", 100)
    obs.obs_data_set_default_int(settings_data, "transition_speed", 300)
    obs.obs_data_set_default_bool(settings_data, "zoom_enabled", false)
    obs.obs_data_set_default_double(settings_data, "zoom_factor", 1.5)

    obs.obs_data_set_default_bool(settings_data, "use_manual_center", false)
    obs.obs_data_set_default_double(settings_data, "center_x", 0)
    obs.obs_data_set_default_double(settings_data, "center_y", 0)
end

function script_update(settings_data)
    settings.debug_enabled = obs.obs_data_get_bool(settings_data, "debug_enabled")
    settings.source_name = obs.obs_data_get_string(settings_data, "source_name")
    settings.screen_width = obs.obs_data_get_int(settings_data, "screen_width")
    settings.screen_height = obs.obs_data_get_int(settings_data, "screen_height")
    settings.zone_mode = obs.obs_data_get_string(settings_data, "zone_mode")
    
    settings.left_percent = obs.obs_data_get_double(settings_data, "left_percent")
    settings.center_percent = obs.obs_data_get_double(settings_data, "center_percent")
    settings.right_percent = obs.obs_data_get_double(settings_data, "right_percent")
    
    settings.z5_left = obs.obs_data_get_double(settings_data, "z5_left")
    settings.z5_lc = obs.obs_data_get_double(settings_data, "z5_lc")
    settings.z5_center = obs.obs_data_get_double(settings_data, "z5_center")
    settings.z5_rc = obs.obs_data_get_double(settings_data, "z5_rc")
    settings.z5_right = obs.obs_data_get_double(settings_data, "z5_right")
    
    settings.z7_left = obs.obs_data_get_double(settings_data, "z7_left")
    settings.z7_lc1 = obs.obs_data_get_double(settings_data, "z7_lc1")
    settings.z7_lc2 = obs.obs_data_get_double(settings_data, "z7_lc2")
    settings.z7_center = obs.obs_data_get_double(settings_data, "z7_center")
    settings.z7_rc1 = obs.obs_data_get_double(settings_data, "z7_rc1")
    settings.z7_rc2 = obs.obs_data_get_double(settings_data, "z7_rc2")
    settings.z7_right = obs.obs_data_get_double(settings_data, "z7_right")
    
    settings.move_x = obs.obs_data_get_bool(settings_data, "move_x")
    settings.move_y = obs.obs_data_get_bool(settings_data, "move_y")
    settings.offset_x_left = obs.obs_data_get_int(settings_data, "offset_x_left")
    settings.offset_x_right = obs.obs_data_get_int(settings_data, "offset_x_right")
    settings.offset_y_up = obs.obs_data_get_int(settings_data, "offset_y_up")
    settings.offset_y_down = obs.obs_data_get_int(settings_data, "offset_y_down")
    settings.transition_speed = obs.obs_data_get_int(settings_data, "transition_speed")
    settings.zoom_enabled = obs.obs_data_get_bool(settings_data, "zoom_enabled")
    settings.zoom_factor = obs.obs_data_get_double(settings_data, "zoom_factor")
    settings.use_manual_center = obs.obs_data_get_bool(settings_data, "use_manual_center")
    settings.center_x = obs.obs_data_get_double(settings_data, "center_x")
    settings.center_y = obs.obs_data_get_double(settings_data, "center_y")
    
    script_settings = settings_data
    log("Configuración actualizada")
end

function script_description()
    return [[
<h2>Zoom To Mouse - Zone Based Movement</h2>
<p>Mueve una fuente basándose en la zona donde está el mouse.</p>
<ul>
<li><b>Modos de Zonas:</b> 3, 5, 7 o 6 (3x2 Cuadrícula)</li>
<li>Manejadores de porcentajes para cada modo</li>
<li>Botón para refrescar y evitar bugs de listas vacías</li>
<li>Opción para ocultar este logger para no molestar</li>
</ul>
<p>Configura el hotkey en <b>Settings → Hotkeys</b> buscando "Zoom To Mouse Toggle"</p>
]]
end

function script_load(settings_data)
    state.hotkey_id = obs.obs_hotkey_register_frontend("zoom_to_mouse_toggle", 
        "Zoom To Mouse Toggle", 
        toggle_enabled)
    
    local hotkey_save_array = obs.obs_data_get_array(settings_data, "zoom_to_mouse_toggle")
    obs.obs_hotkey_load(state.hotkey_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
    
    log("Script cargado correctamente")
end

function script_save(settings_data)
    local hotkey_save_array = obs.obs_hotkey_save(state.hotkey_id)
    obs.obs_data_set_array(settings_data, "zoom_to_mouse_toggle", hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
end

function script_unload()
    if state.enabled then
        obs.timer_remove(animation_tick)
        restore_original_transform()
    end
    log("Script descargado")
end
