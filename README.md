# OBS Zoom to Mouse (SINZOOM Script)

Un script en Lua para **OBS Studio** (Windows) que despliega un flujo dinámico para desplazar y enfocar (zoom opcional) sobre una de tus fuentes o escenas de video automáticamente, todo ello sincronizado con la posición en tiempo real de tu ratón.

## 🚀 Características Principales

1. **Sin Límite de Píxeles:** Desplaza la fuente usando valores precisos y masivos (hasta `100000 px`), saltándose el antiguo y problemático límite de 2000px, perfecto para altas resoluciones escaladas.
2. **Diversas Zonas Configurables:** Se divide el espacio de pantalla en múltiples áreas proporcionales que reaccionan de manera distinta.
    - **3 Zonas:** (Izquierda / Centro / Derecha).
    - **5 Zonas:** (Izquierda / Izquierda Centro / Centro / Derecha Centro / Derecha).
    - **7 Zonas:** Granularidad máxima con deslizadores dinámicos que detectan movimiento hiper precíso.
    - **6 Zonas (3x2):** Detecta también en el eje Y (Arriba / Abajo).
3. **Guardado de Presets Automático:** ¡No más volver a tipear! Puedes nombrar tu configuración, pulsar "Guardar", y se guardará toda la información a un archivo local `zoom_presets.lua.txt`. Solo selecciona el preset de la lista en cualquier momento y pulsa en "Cargar" para cambiar rápidamente como funciona la cámara.
4. **Deslizadores Proporcionales (Manejadores):** Configura visualmente la sensibilidad (porcentaje en píxeles) de tus zonas personalizadas; cada modo de visualización te permite elegir cuánto ocupa cada zona.

## ⚙️ Instalación en OBS Studio

1. Clona o descarga el archivo `zoom-to-mouse-SINZOOM.lua` de este repositorio.
2. Abre **OBS Studio**.
3. Ve al menú superior **Herramientas** (Tools) > **Scripts**.
4. Pulsa en la pestaña de `Scripts` el icono de **"+" (Añadir Script)**.
5. Busca el archivo que descargaste e impórtalo.
6. A la derecha verás todas las propiedades del plugin.

## 💡 Cómo se Usa

### Configuración inicial:
- **Habilitar Logger de Debug**: Activado por defecto y muy útil para confirmar zonas, posiciones actuales y cargas. Si la ventana de Script te lanza muchos mensajes, símplemente quítale el tick desde aquí.
- **Fuente a mover:** Elige en el desplegable la pantalla/webcam/grupo que se intentará mover mediante transformación. Si no aparece, asegúrate de que no es solo un track de audio, y pulsa en **"Refrescar lista de fuentes"**.
- **Ancho y Alto:** Fíja de manera manual la resolución total real física de la pantalla completa desde la que recoges el movimiento del ratón.
- **Modo de Zonas:** Elige el mapeo que va a dividir la pantalla. Al elegirlo verás que los manejadores cambian automáticamente ofreciendo variables como (20% en 5 Zonas, ó 14.28% en 7 Zonas).
- **Posición Central Manual:** Utiliza la coordenada en X/Y que desees forzar como eje central.

### El Sistema de Presets
Este era el paso final fundamental para un flujo ágil. En la sección **--- PRESETS ---**:

1. Ingresa un nombre que quieras (acepta espacios, ejemplo: `Valorant Competitivo - 7 Zonas`).
2. Toca **"Guardar Preset Actual"**. Te creará un archivo automático junto al .lua que no debes perder.
3. Este nombre aparecerá ahora en la caja desplegable `"Seleccionar Preset"`.
4. Si quieres cargar todo, selecciónalo de la lista y presiona **"Cargar Preset"**. Toda tu UI se restablecerá y el script se actualizará al instante.

### ¿Cómo lo Activo en mis Escenas?
Para que tu fuente no se vuelva loca, este Plugin funciona únicamente con un "Botón" de atajo (Hotkey):
1. En OBS, ve a **Ajustes** > **Atajos** (Hotkeys).
2. En la barra de filtro teclea `"Zoom To Mouse Toggle"`.
3. Asígale una tecla global (por ejemplo: `F9` o un botón de tu StreamDeck).
4. Cuando lo presiones, arrancará a seguir tu ratón. Cuando lo sueltes, la cámara / fuente regresará educadamente a la transformación `Posición Original` antes del movimiento.

## 📝 Notas importantes
- Para que la escala o Zoom no se pierda al desactivar el tracking, su origen / transformación es compensada y vuelta a colocar al original.
- Para evitar bugs tras actualizar el plugin de una versión antigua en OBS, si un preset o manejador da problemas, simplemente cierra y abre de nuevo tu instancia de Scripts y dale a `Refrescar`.
- El archivo de configuración `zoom_presets.lua.txt` se guarda como una tabla de Lua (una versión sanitizada que se salta la codificación estricta); ni se te ocurra borrar o trastear manualmente este `.txt` si no sabes Lua! Simplemente borra tu preset desde el botón en la UI de OBS.
