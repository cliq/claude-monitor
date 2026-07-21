/* LVGL configuration — only overrides; lv_conf_internal.h supplies defaults. */
#ifndef LV_CONF_H
#define LV_CONF_H

#define LV_COLOR_DEPTH 16
#define LV_COLOR_16_SWAP 0 /* parallel RGB panel: no byte swap */

/* Route LVGL's heap to PSRAM: the GIF decoder needs ~1 MB canvas buffers,
 * far beyond what fits in internal RAM. */
#define LV_MEM_CUSTOM 1
#define LV_MEM_CUSTOM_INCLUDE "esp32-hal-psram.h"
#define LV_MEM_CUSTOM_ALLOC ps_malloc
#define LV_MEM_CUSTOM_FREE free
#define LV_MEM_CUSTOM_REALLOC ps_realloc

/* Animated GIF playback (mascot celebrations). */
#define LV_USE_GIF 1

#define LV_TICK_CUSTOM 1
#define LV_TICK_CUSTOM_INCLUDE "Arduino.h"
#define LV_TICK_CUSTOM_SYS_TIME_EXPR (millis())

#define LV_FONT_MONTSERRAT_12 1
#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_16 1
#define LV_FONT_MONTSERRAT_36 1
#define LV_FONT_DEFAULT &lv_font_montserrat_14

#endif
