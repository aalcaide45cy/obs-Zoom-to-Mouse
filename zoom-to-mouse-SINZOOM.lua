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
    source_name = "",
    zone_mode = "3zones",       -- "3zones" o "6zones"
    left_percent = 33.33,
    center_percent = 33.33,
    right_percent = 33.33,
    move_x = true,
    move_y = false,
    -- Desplazamientos individuales por dirección
    offset_x_left = 100,   -- Cuánto se mueve cuando mouse va a la izquierda
    offset_x_right = 100,  -- Cuánto se mueve cuando mouse va a la derecha
    offset_y_up = 100,     -- Cuánto se mueve cuando mouse va arriba
    offset_y_down = 100,   -- Cuánto se mueve cuando mouse va abajo
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
    -- Tamaño de la fuente (para compensar zoom)
    source_width = 0,
    source_height = 0,
    -- Posición de INICIO de la animación actual
    start_pos = { x = 0, y = 0 },
    start_scale = { x = 1, y = 1 },
    -- Posición actual (interpolada)
    current_pos = { x = 0, y = 0 },
    current_scale = { x = 1, y = 1 },
    -- Posición objetivo
    target_pos = { x = 0, y = 0 },
    target_scale = { x = 1, y = 1 },
    current_zone = { h = "center", v = "center" },
    animation_progress = 1.0,
    is_animating = false,
}

-- ============================================================================
-- UTILIDADES
-- ============================================================================

--- Interpolación lineal
local function lerp(a, b, t)
    return a + (b - a) * t
end

--- Easing ease-out cubic para movimiento suave
local function ease_out_cubic(t)
    return 1 - math.pow(1 - t, 3)
end

--- Clamp un valor entre min y max
local function clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

--- Log de debug
local function log(msg)
    obs.script_log(obs.OBS_LOG_INFO, "[ZoomToMouse] " .. msg)
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

--- Determina en qué zona horizontal está el mouse
local function get_horizontal_zone(mouse_x)
    local screen_w = settings.screen_width
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

--- Determina en qué zona vertical está el mouse (para modo 6 zonas)
local function get_vertical_zone(mouse_y)
    local screen_h = settings.screen_height
    local half = screen_h / 2
    
    if mouse_y < half then
        return "top"
    else
        return "bottom"
    end
end

--- Obtiene la zona actual del mouse
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

--- Calcula la posición objetivo basada en la zona
local function calculate_target_position(zone, mouse_pos)
    local target = {
        x = state.original_pos.x,
        y = state.original_pos.y
    }
    
    -- Movimiento horizontal basado en zona
    if settings.move_x then
        if zone.h == "left" then
            -- Mouse a la izquierda -> mover fuente a la derecha (offset_x_left)
            target.x = state.original_pos.x + settings.offset_x_left
        elseif zone.h == "right" then
            -- Mouse a la derecha -> mover fuente a la izquierda (offset_x_right)
            target.x = state.original_pos.x - settings.offset_x_right
        else
            -- Centro -> posición original
            target.x = state.original_pos.x
        end
    end
    
    -- Movimiento vertical basado en zona (solo en modo 6 zonas)
    if settings.move_y and settings.zone_mode == "6zones" then
        if zone.v == "top" then
            -- Mouse arriba -> mover fuente abajo (offset_y_up)
            target.y = state.original_pos.y + settings.offset_y_up
        elseif zone.v == "bottom" then
            -- Mouse abajo -> mover fuente arriba (offset_y_down)
            target.y = state.original_pos.y - settings.offset_y_down
        else
            target.y = state.original_pos.y
        end
    end
    
    -- COMPENSACIÓN DE ZOOM: cuando hacemos zoom, la fuente crece desde su punto de anclaje
    -- Para mantener el centro visual en el mismo lugar, debemos mover la posición
    if settings.zoom_enabled and state.source_width > 0 and state.source_height > 0 then
        -- Calcular cuánto crece la fuente con el zoom
        local size_increase_x = state.source_width * state.original_scale.x * (settings.zoom_factor - 1)
        local size_increase_y = state.source_height * state.original_scale.y * (settings.zoom_factor - 1)
        
        -- Compensar moviendo la posición hacia arriba-izquierda (la mitad del crecimiento)
        target.x = target.x - (size_increase_x / 2)
        target.y = target.y - (size_increase_y / 2)
    end
    
    return target
end

--- Calcula la escala objetivo para el zoom
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
    local source = obs.obs_get_source_by_name(settings.source_name)
    if source == nil then
        return nil
    end
    
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

--- Guarda la posición y escala original de la fuente
local function save_original_transform()
    local sceneitem = get_sceneitem()
    if sceneitem == nil then
        log("No se pudo encontrar la fuente: " .. settings.source_name)
        return false
    end
    
    -- Obtener source para conseguir su tamaño base
    local source = obs.obs_get_source_by_name(settings.source_name)
    if source ~= nil then
        state.source_width = obs.obs_source_get_width(source)
        state.source_height = obs.obs_source_get_height(source)
        obs.obs_source_release(source)
        log("Tamaño de fuente: " .. state.source_width .. "x" .. state.source_height)
    end
    
    -- Obtener posición actual de la fuente
    local pos = obs.vec2()
    obs.obs_sceneitem_get_pos(sceneitem, pos)
    
    -- Usar posición manual si está configurada, sino usar la posición actual
    if settings.use_manual_center then
        state.original_pos.x = settings.center_x
        state.original_pos.y = settings.center_y
        log("Usando posición central manual: " .. settings.center_x .. ", " .. settings.center_y)
    else
        state.original_pos.x = pos.x
        state.original_pos.y = pos.y
        log("Usando posición actual: " .. pos.x .. ", " .. pos.y)
    end
    
    -- Inicializar todas las posiciones
    state.start_pos.x = pos.x
    state.start_pos.y = pos.y
    state.current_pos.x = pos.x
    state.current_pos.y = pos.y
    state.target_pos.x = state.original_pos.x
    state.target_pos.y = state.original_pos.y
    
    local scale = obs.vec2()
    obs.obs_sceneitem_get_scale(sceneitem, scale)
    state.original_scale.x = scale.x
    state.original_scale.y = scale.y
    state.start_scale.x = scale.x
    state.start_scale.y = scale.y
    state.current_scale.x = scale.x
    state.current_scale.y = scale.y
    state.target_scale.x = scale.x
    state.target_scale.y = scale.y
    
    -- Resetear zona a ninguna para forzar primera animación
    state.current_zone = { h = "none", v = "none" }
    state.animation_progress = 1.0
    state.is_animating = false
    
    return true
end

--- Captura la posición actual de la fuente como posición central
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
    
    -- Guardar en settings
    settings.center_x = pos.x
    settings.center_y = pos.y
    
    -- Actualizar los datos guardados
    if script_settings ~= nil then
        obs.obs_data_set_double(script_settings, "center_x", pos.x)
        obs.obs_data_set_double(script_settings, "center_y", pos.y)
    end
    
    log("Posición central capturada: " .. pos.x .. ", " .. pos.y)
    return true
end

--- Restaura la transformación original
local function restore_original_transform()
    local sceneitem = get_sceneitem()
    if sceneitem == nil then
        return
    end
    
    local pos = obs.vec2()
    pos.x = state.original_pos.x
    pos.y = state.original_pos.y
    obs.obs_sceneitem_set_pos(sceneitem, pos)
    
    -- Siempre restaurar escala (por si se usó zoom antes)
    local scale = obs.vec2()
    scale.x = state.original_scale.x
    scale.y = state.original_scale.y
    obs.obs_sceneitem_set_scale(sceneitem, scale)
    
    state.current_pos.x = state.original_pos.x
    state.current_pos.y = state.original_pos.y
    state.current_scale.x = state.original_scale.x
    state.current_scale.y = state.original_scale.y
    
    log("Transformación restaurada")
end

-- ============================================================================
-- LOOP PRINCIPAL DE ANIMACIÓN
-- ============================================================================

local last_time = 0
local FRAME_TIME = 16  -- ~60fps en milisegundos

local function animation_tick()
    if not state.enabled then
        return
    end
    
    -- Obtener posición del mouse
    local mouse_pos = get_mouse_pos()
    
    -- Determinar zona actual
    local new_zone = get_current_zone(mouse_pos)
    
    -- Si cambió de zona, iniciar nueva animación
    if new_zone.h ~= state.current_zone.h or new_zone.v ~= state.current_zone.v then
        -- Guardar posición ACTUAL como inicio de la nueva animación
        state.start_pos.x = state.current_pos.x
        state.start_pos.y = state.current_pos.y
        state.start_scale.x = state.current_scale.x
        state.start_scale.y = state.current_scale.y
        
        -- Actualizar zona y calcular nuevo objetivo
        state.current_zone = new_zone
        state.target_pos = calculate_target_position(new_zone, mouse_pos)
        state.target_scale = calculate_target_scale(mouse_pos)
        
        -- Resetear progreso de animación
        state.animation_progress = 0
        state.is_animating = true
        log("Cambio de zona: " .. new_zone.h .. " / " .. new_zone.v)
    end
    
    -- Animar si es necesario
    if state.is_animating then
        -- Calcular progreso basado en velocidad de transición
        local progress_increment = FRAME_TIME / settings.transition_speed
        state.animation_progress = clamp(state.animation_progress + progress_increment, 0, 1)
        
        -- Aplicar easing
        local eased_progress = ease_out_cubic(state.animation_progress)
        
        -- Interpolar posición: desde START hacia TARGET (no desde current!)
        state.current_pos.x = lerp(state.start_pos.x, state.target_pos.x, eased_progress)
        state.current_pos.y = lerp(state.start_pos.y, state.target_pos.y, eased_progress)
        
        -- Interpolar escala si zoom está habilitado
        if settings.zoom_enabled then
            state.current_scale.x = lerp(state.start_scale.x, state.target_scale.x, eased_progress)
            state.current_scale.y = lerp(state.start_scale.y, state.target_scale.y, eased_progress)
        end
        
        -- Aplicar transformación
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
        
        -- Verificar si terminó la animación
        if state.animation_progress >= 1.0 then
            state.is_animating = false
        end
    end
end

-- ============================================================================
-- HOTKEY TOGGLE
-- ============================================================================

local function toggle_enabled(pressed)
    if not pressed then
        return
    end
    
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

function script_properties()
    local props = obs.obs_properties_create()
    
    -- Información
    obs.obs_properties_add_text(props, "info", 
        "Zoom To Mouse - Zone Based Movement\n" ..
        "Activa con el hotkey configurado en Settings → Hotkeys",
        obs.OBS_TEXT_INFO)
    
    -- Selector de fuente
    local source_list = obs.obs_properties_add_list(props, "source_name", 
        "Fuente a mover", 
        obs.OBS_COMBO_TYPE_LIST, 
        obs.OBS_COMBO_FORMAT_STRING)
    
    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local name = obs.obs_source_get_name(source)
            obs.obs_property_list_add_string(source_list, name, name)
        end
        obs.source_list_release(sources)
    end
    
    -- Botón para refrescar lista de fuentes
    obs.obs_properties_add_button(props, "refresh_sources", "Refrescar lista de fuentes", 
        function(props_arg, prop)
            -- Esto recarga las propiedades, actualizando la lista
            return true
        end)
    
    -- Resolución de pantalla
    obs.obs_properties_add_int(props, "screen_width", "Ancho de pantalla", 640, 7680, 1)
    obs.obs_properties_add_int(props, "screen_height", "Alto de pantalla", 480, 4320, 1)
    
    -- Modo de zonas
    local zone_mode = obs.obs_properties_add_list(props, "zone_mode",
        "Modo de zonas",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(zone_mode, "3 Zonas (Izq/Centro/Der)", "3zones")
    obs.obs_property_list_add_string(zone_mode, "6 Zonas (3x2 cuadrícula)", "6zones")
    
    -- Porcentajes de zonas
    obs.obs_properties_add_float_slider(props, "left_percent", "% Zona Izquierda", 5, 90, 0.1)
    obs.obs_properties_add_float_slider(props, "center_percent", "% Zona Centro", 5, 90, 0.1)
    obs.obs_properties_add_float_slider(props, "right_percent", "% Zona Derecha", 5, 90, 0.1)
    
    -- Ejes de movimiento
    obs.obs_properties_add_bool(props, "move_x", "Mover en eje X")
    obs.obs_properties_add_bool(props, "move_y", "Mover en eje Y (solo modo 6 zonas)")
    
    -- Offset de movimiento (individuales por dirección)
    obs.obs_properties_add_int(props, "offset_x_left", "Desplazamiento cuando mouse IZQUIERDA (px)", 0, 2000, 10)
    obs.obs_properties_add_int(props, "offset_x_right", "Desplazamiento cuando mouse DERECHA (px)", 0, 2000, 10)
    obs.obs_properties_add_int(props, "offset_y_up", "Desplazamiento cuando mouse ARRIBA (px)", 0, 2000, 10)
    obs.obs_properties_add_int(props, "offset_y_down", "Desplazamiento cuando mouse ABAJO (px)", 0, 2000, 10)
    
    -- Velocidad de transición
    obs.obs_properties_add_int(props, "transition_speed", "Velocidad transición (ms)", 50, 2000, 50)
    
    -- Zoom
    obs.obs_properties_add_bool(props, "zoom_enabled", "Habilitar Zoom")
    obs.obs_properties_add_float_slider(props, "zoom_factor", "Factor de Zoom", 1.0, 4.0, 0.1)
    
    -- Separador
    obs.obs_properties_add_text(props, "separator", "--- POSICIÓN CENTRAL ---", obs.OBS_TEXT_INFO)
    
    -- Usar posición manual
    obs.obs_properties_add_bool(props, "use_manual_center", "Usar posición central manual")
    
    -- Campos para posición central
    obs.obs_properties_add_float(props, "center_x", "Posición X central", -10000, 10000, 1)
    obs.obs_properties_add_float(props, "center_y", "Posición Y central", -10000, 10000, 1)
    
    -- Botón para capturar posición actual
    obs.obs_properties_add_button(props, "capture_center", "Capturar posición actual como centro", capture_center_position)
    
    return props
end

--- Valores por defecto
function script_defaults(settings_data)
    obs.obs_data_set_default_string(settings_data, "source_name", "")
    obs.obs_data_set_default_int(settings_data, "screen_width", 1920)
    obs.obs_data_set_default_int(settings_data, "screen_height", 1080)
    obs.obs_data_set_default_string(settings_data, "zone_mode", "3zones")
    obs.obs_data_set_default_double(settings_data, "left_percent", 33.33)
    obs.obs_data_set_default_double(settings_data, "center_percent", 33.33)
    obs.obs_data_set_default_double(settings_data, "right_percent", 33.33)
    obs.obs_data_set_default_bool(settings_data, "move_x", true)
    obs.obs_data_set_default_bool(settings_data, "move_y", false)
    obs.obs_data_set_default_int(settings_data, "offset_x_left", 100)
    obs.obs_data_set_default_int(settings_data, "offset_x_right", 100)
    obs.obs_data_set_default_int(settings_data, "offset_y_up", 100)
    obs.obs_data_set_default_int(settings_data, "offset_y_down", 100)
    obs.obs_data_set_default_int(settings_data, "transition_speed", 300)
    obs.obs_data_set_default_bool(settings_data, "zoom_enabled", false)
    obs.obs_data_set_default_double(settings_data, "zoom_factor", 1.5)
    -- Posición central
    obs.obs_data_set_default_bool(settings_data, "use_manual_center", false)
    obs.obs_data_set_default_double(settings_data, "center_x", 0)
    obs.obs_data_set_default_double(settings_data, "center_y", 0)
end

--- Actualizar configuración cuando el usuario cambia algo
function script_update(settings_data)
    settings.source_name = obs.obs_data_get_string(settings_data, "source_name")
    settings.screen_width = obs.obs_data_get_int(settings_data, "screen_width")
    settings.screen_height = obs.obs_data_get_int(settings_data, "screen_height")
    settings.zone_mode = obs.obs_data_get_string(settings_data, "zone_mode")
    settings.left_percent = obs.obs_data_get_double(settings_data, "left_percent")
    settings.center_percent = obs.obs_data_get_double(settings_data, "center_percent")
    settings.right_percent = obs.obs_data_get_double(settings_data, "right_percent")
    settings.move_x = obs.obs_data_get_bool(settings_data, "move_x")
    settings.move_y = obs.obs_data_get_bool(settings_data, "move_y")
    settings.offset_x_left = obs.obs_data_get_int(settings_data, "offset_x_left")
    settings.offset_x_right = obs.obs_data_get_int(settings_data, "offset_x_right")
    settings.offset_y_up = obs.obs_data_get_int(settings_data, "offset_y_up")
    settings.offset_y_down = obs.obs_data_get_int(settings_data, "offset_y_down")
    settings.transition_speed = obs.obs_data_get_int(settings_data, "transition_speed")
    settings.zoom_enabled = obs.obs_data_get_bool(settings_data, "zoom_enabled")
    settings.zoom_factor = obs.obs_data_get_double(settings_data, "zoom_factor")
    -- Posición central
    settings.use_manual_center = obs.obs_data_get_bool(settings_data, "use_manual_center")
    settings.center_x = obs.obs_data_get_double(settings_data, "center_x")
    settings.center_y = obs.obs_data_get_double(settings_data, "center_y")
    
    -- Guardar referencia global para el botón de captura
    script_settings = settings_data
    
    log("Configuración actualizada")
end

-- ============================================================================
-- FUNCIONES DEL SCRIPT
-- ============================================================================

function script_description()
    return [[
<h2>Zoom To Mouse - Zone Based Movement</h2>
<p>Mueve una fuente basándose en la zona donde está el mouse.</p>
<ul>
<li><b>Modo 3 Zonas:</b> Izquierda, Centro, Derecha</li>
<li><b>Modo 6 Zonas:</b> Cuadrícula 3x2</li>
</ul>
<p>Configura el hotkey en <b>Settings → Hotkeys</b> buscando "Zoom To Mouse Toggle"</p>
]]
end

function script_load(settings_data)
    -- Registrar hotkey
    state.hotkey_id = obs.obs_hotkey_register_frontend("zoom_to_mouse_toggle", 
        "Zoom To Mouse Toggle", 
        toggle_enabled)
    
    -- Cargar hotkey guardado
    local hotkey_save_array = obs.obs_data_get_array(settings_data, "zoom_to_mouse_toggle")
    obs.obs_hotkey_load(state.hotkey_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
    
    log("Script cargado correctamente")
end

function script_save(settings_data)
    -- Guardar hotkey
    local hotkey_save_array = obs.obs_hotkey_save(state.hotkey_id)
    obs.obs_data_set_array(settings_data, "zoom_to_mouse_toggle", hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
end

function script_unload()
    -- Limpiar timer si está corriendo
    if state.enabled then
        obs.timer_remove(animation_tick)
        restore_original_transform()
    end
    log("Script descargado")
end
