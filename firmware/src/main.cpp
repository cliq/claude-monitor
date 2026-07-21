/* Claude usage monitor for Guition ESP32-S3-4848S040 (480x480 ST7701S RGB panel).
 * Polls the usage bridge over WiFi and renders 3 accounts x 3 limits with LVGL.
 */
#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <lvgl.h>
#include <Arduino_GFX_Library.h>
#include <time.h>
#include <string.h>
#include "secrets.h"
#include "mascot_gifs.h"

/* ---------- Display (pins from vendor demo for 4848S040) ---------- */
#define GFX_BL 38

Arduino_DataBus *bus = new Arduino_SWSPI(
    GFX_NOT_DEFINED /* DC */, 39 /* CS */, 48 /* SCK */, 47 /* MOSI */, GFX_NOT_DEFINED /* MISO */);

Arduino_ESP32RGBPanel *rgbpanel = new Arduino_ESP32RGBPanel(
    18 /* DE */, 17 /* VSYNC */, 16 /* HSYNC */, 21 /* PCLK */,
    11 /* R0 */, 12 /* R1 */, 13 /* R2 */, 14 /* R3 */, 0 /* R4 */,
    8 /* G0 */, 20 /* G1 */, 3 /* G2 */, 46 /* G3 */, 9 /* G4 */, 10 /* G5 */,
    4 /* B0 */, 5 /* B1 */, 6 /* B2 */, 7 /* B3 */, 15 /* B4 */,
    1 /* hsync_polarity */, 10 /* hsync_front_porch */, 8 /* hsync_pulse_width */, 50 /* hsync_back_porch */,
    1 /* vsync_polarity */, 10 /* vsync_front_porch */, 8 /* vsync_pulse_width */, 20 /* vsync_back_porch */);

/* st7701_type1_init_operations with inversion OFF (0x20): this panel batch
 * shows a negative image with the library's default 0x21. */
static const uint8_t st7701_4848s040_init_operations[] = {
    BEGIN_WRITE,
    WRITE_COMMAND_8, 0xFF,
    WRITE_BYTES, 5, 0x77, 0x01, 0x00, 0x00, 0x10,
    WRITE_C8_D16, 0xC0, 0x3B, 0x00,
    WRITE_C8_D16, 0xC1, 0x0D, 0x02,
    WRITE_C8_D16, 0xC2, 0x31, 0x05,
    WRITE_C8_D8, 0xCD, 0x00, // MDT flag off (0x08 scrambles 16-bit color on this panel)
    WRITE_COMMAND_8, 0xB0,
    WRITE_BYTES, 16,
    0x00, 0x11, 0x18, 0x0E,
    0x11, 0x06, 0x07, 0x08,
    0x07, 0x22, 0x04, 0x12,
    0x0F, 0xAA, 0x31, 0x18,
    WRITE_COMMAND_8, 0xB1,
    WRITE_BYTES, 16,
    0x00, 0x11, 0x19, 0x0E,
    0x12, 0x07, 0x08, 0x08,
    0x08, 0x22, 0x04, 0x11,
    0x11, 0xA9, 0x32, 0x18,
    WRITE_COMMAND_8, 0xFF,
    WRITE_BYTES, 5, 0x77, 0x01, 0x00, 0x00, 0x11,
    WRITE_C8_D8, 0xB0, 0x60,
    WRITE_C8_D8, 0xB1, 0x32,
    WRITE_C8_D8, 0xB2, 0x07,
    WRITE_C8_D8, 0xB3, 0x80,
    WRITE_C8_D8, 0xB5, 0x49,
    WRITE_C8_D8, 0xB7, 0x85,
    WRITE_C8_D8, 0xB8, 0x21,
    WRITE_C8_D8, 0xC1, 0x78,
    WRITE_C8_D8, 0xC2, 0x78,
    WRITE_COMMAND_8, 0xE0,
    WRITE_BYTES, 3, 0x00, 0x1B, 0x02,
    WRITE_COMMAND_8, 0xE1,
    WRITE_BYTES, 11,
    0x08, 0xA0, 0x00, 0x00,
    0x07, 0xA0, 0x00, 0x00,
    0x00, 0x44, 0x44,
    WRITE_COMMAND_8, 0xE2,
    WRITE_BYTES, 12,
    0x11, 0x11, 0x44, 0x44,
    0xED, 0xA0, 0x00, 0x00,
    0xEC, 0xA0, 0x00, 0x00,
    WRITE_COMMAND_8, 0xE3,
    WRITE_BYTES, 4, 0x00, 0x00, 0x11, 0x11,
    WRITE_C8_D16, 0xE4, 0x44, 0x44,
    WRITE_COMMAND_8, 0xE5,
    WRITE_BYTES, 16,
    0x0A, 0xE9, 0xD8, 0xA0,
    0x0C, 0xEB, 0xD8, 0xA0,
    0x0E, 0xED, 0xD8, 0xA0,
    0x10, 0xEF, 0xD8, 0xA0,
    WRITE_COMMAND_8, 0xE6,
    WRITE_BYTES, 4, 0x00, 0x00, 0x11, 0x11,
    WRITE_C8_D16, 0xE7, 0x44, 0x44,
    WRITE_COMMAND_8, 0xE8,
    WRITE_BYTES, 16,
    0x09, 0xE8, 0xD8, 0xA0,
    0x0B, 0xEA, 0xD8, 0xA0,
    0x0D, 0xEC, 0xD8, 0xA0,
    0x0F, 0xEE, 0xD8, 0xA0,
    WRITE_COMMAND_8, 0xEB,
    WRITE_BYTES, 7,
    0x02, 0x00, 0xE4, 0xE4,
    0x88, 0x00, 0x40,
    WRITE_C8_D16, 0xEC, 0x3C, 0x00,
    WRITE_COMMAND_8, 0xED,
    WRITE_BYTES, 16,
    0xAB, 0x89, 0x76, 0x54,
    0x02, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0x20,
    0x45, 0x67, 0x98, 0xBA,
    WRITE_COMMAND_8, 0xFF,
    WRITE_BYTES, 5, 0x77, 0x01, 0x00, 0x00, 0x13,
    WRITE_C8_D8, 0xE5, 0xE4,
    WRITE_COMMAND_8, 0xFF,
    WRITE_BYTES, 5, 0x77, 0x01, 0x00, 0x00, 0x00,
    WRITE_COMMAND_8, 0x20,   // inversion off (library default 0x21 inverts on this panel)
    WRITE_C8_D8, 0x3A, 0x60, // RGB666
    WRITE_COMMAND_8, 0x11,   // Sleep Out
    END_WRITE,
    DELAY, 120,
    BEGIN_WRITE,
    WRITE_COMMAND_8, 0x29, // Display On
    END_WRITE};

Arduino_RGB_Display *gfx = new Arduino_RGB_Display(
    480, 480, rgbpanel, 0 /* rotation */, true /* auto_flush */,
    bus, GFX_NOT_DEFINED /* RST */, st7701_4848s040_init_operations, sizeof(st7701_4848s040_init_operations));

/* ---------- Palette ---------- */
#define C_BG 0x14110D
#define C_STATUS_BG 0x0F0D0A
#define C_LINE 0x241F19
#define C_TEXT 0xEDE6DB
#define C_MUTED 0x6E6558
#define C_RESET 0x8A8072
#define C_IDLE 0x55503F
#define C_NAME 0xD97757
#define C_SAND 0xC9BFAF
#define C_WARN 0xE3A455
#define C_CRIT 0xE25A3F
#define C_TRACK 0x262119
#define C_OK_DOT 0x8FAE6E

/* Show the live "Xs ago" data-age counter in the status bar. Override with
 * -DSHOW_DATA_AGE=0 in platformio.ini if the refreshing label is distracting;
 * a stale bridge is still flagged either way. */
#ifndef SHOW_DATA_AGE
#define SHOW_DATA_AGE 1
#endif

#define N_ACCOUNTS 3
#define N_METRICS 3
#define POLL_MS 60000UL
#define STALE_MS (POLL_MS * 3)

static const char *METRIC_LABELS[N_METRICS] = {"SESSION", "WEEKLY", "FABLE"};

struct MetricW {
  lv_obj_t *value;
  lv_obj_t *pct;
  lv_obj_t *bar;
  lv_obj_t *reset;
};
struct AccountW {
  lv_obj_t *row; /* container for the whole row; hidden when unused */
  lv_obj_t *name;
  lv_obj_t *plan;
  MetricW m[N_METRICS];
};
static AccountW ui[N_ACCOUNTS];

/* Reset detection: utilization is monotonic within a window, so any drop from a
 * positive value means that window reset. -2 = no reading yet (skip). */
static int prev_session_pct[N_ACCOUNTS] = {-2, -2, -2};
static int prev_weekly_pct[N_ACCOUNTS] = {-2, -2, -2};
static void celebrate_session(int acct);
static void celebrate_weekly(int acct);
static lv_obj_t *status_left, *status_clock, *status_dot;

static lv_disp_draw_buf_t draw_buf;
static lv_color_t *buf1;
static lv_disp_drv_t disp_drv;

static uint32_t last_fetch_ok = 0; /* millis of last successful poll, 0 = never */
static uint32_t last_fetch_try = 0;
static uint32_t last_status_tick = 0;

/* Instrumentation: count flushes overall, and count gif frames by the first
 * strip of each redraw (top-left corner of the gif area). */
static volatile uint32_t g_flushes = 0, g_frames = 0;
static lv_coord_t g_gifx = -1, g_gify = -1;

static void disp_flush(lv_disp_drv_t *disp, const lv_area_t *area, lv_color_t *color_p) {
  uint32_t w = area->x2 - area->x1 + 1;
  uint32_t h = area->y2 - area->y1 + 1;
  gfx->draw16bitRGBBitmap(area->x1, area->y1, (uint16_t *)&color_p->full, w, h);
  lv_disp_flush_ready(disp);
  g_flushes++;
  if (area->x1 == g_gifx && area->y1 == g_gify) g_frames++;
}

static lv_obj_t *make_label(lv_obj_t *parent, const lv_font_t *font, uint32_t color,
                            lv_coord_t x, lv_coord_t y, const char *text) {
  lv_obj_t *l = lv_label_create(parent);
  lv_obj_set_style_text_font(l, font, 0);
  lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
  lv_obj_set_pos(l, x, y);
  lv_label_set_text(l, text);
  return l;
}

static void build_ui() {
  lv_obj_t *scr = lv_scr_act();
  lv_obj_set_style_bg_color(scr, lv_color_hex(C_BG), 0);
  lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
  lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

  const lv_coord_t row_h = 151;   /* (480 - 27 status) / 3 */
  /* 20px margin on both sides: 3 x 136 columns + 2 x 16 gaps = 440 */
  const lv_coord_t col_x[N_METRICS] = {20, 172, 324};
  const lv_coord_t col_w = 136;

  for (int i = 0; i < N_ACCOUNTS; i++) {
    /* Each row is a container so an unused account (fewer than N_ACCOUNTS in the
     * feed) can be hidden wholesale, separator included. Child positions are
     * relative to the row, so drop the per-row y offset. */
    lv_obj_t *row = lv_obj_create(scr);
    lv_obj_set_pos(row, 0, i * row_h);
    lv_obj_set_size(row, 480, row_h);
    lv_obj_set_style_bg_color(row, lv_color_hex(C_BG), 0);
    lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(row, 0, 0);
    lv_obj_set_style_radius(row, 0, 0);
    lv_obj_set_style_pad_all(row, 0, 0);
    lv_obj_clear_flag(row, LV_OBJ_FLAG_SCROLLABLE);
    ui[i].row = row;

    ui[i].name = make_label(row, &lv_font_montserrat_14, C_NAME, 20, 12, "-");
    lv_obj_set_style_text_letter_space(ui[i].name, 2, 0);
    ui[i].plan = make_label(row, &lv_font_montserrat_12, C_MUTED, 20, 14, "");

    for (int j = 0; j < N_METRICS; j++) {
      lv_coord_t x = col_x[j];
      MetricW *m = &ui[i].m[j];

      lv_obj_t *lab = make_label(row, &lv_font_montserrat_12, C_MUTED, x, 40, METRIC_LABELS[j]);
      lv_obj_set_style_text_letter_space(lab, 1, 0);

      m->value = make_label(row, &lv_font_montserrat_36, C_IDLE, x, 56, "-");
      m->pct = make_label(row, &lv_font_montserrat_16, C_MUTED, x, 74, "");

      m->bar = lv_bar_create(row);
      lv_obj_set_pos(m->bar, x, 100);
      lv_obj_set_size(m->bar, col_w, 5);
      lv_bar_set_range(m->bar, 0, 100);
      lv_bar_set_value(m->bar, 0, LV_ANIM_OFF);
      lv_obj_set_style_radius(m->bar, 3, LV_PART_MAIN);
      lv_obj_set_style_bg_color(m->bar, lv_color_hex(C_TRACK), LV_PART_MAIN);
      lv_obj_set_style_bg_opa(m->bar, LV_OPA_COVER, LV_PART_MAIN);
      lv_obj_set_style_radius(m->bar, 3, LV_PART_INDICATOR);
      lv_obj_set_style_bg_color(m->bar, lv_color_hex(C_SAND), LV_PART_INDICATOR);
      lv_obj_set_style_bg_opa(m->bar, LV_OPA_COVER, LV_PART_INDICATOR);

      m->reset = make_label(row, &lv_font_montserrat_14, C_RESET, x, 114, "");
    }

    /* Separator at the TOP of rows below the first, so hiding a row also hides
     * the line above it (a single-account feed shows one clean card). */
    if (i > 0) {
      lv_obj_t *sep = lv_obj_create(row);
      lv_obj_set_pos(sep, 0, 0);
      lv_obj_set_size(sep, 480, 1);
      lv_obj_set_style_bg_color(sep, lv_color_hex(C_LINE), 0);
      lv_obj_set_style_bg_opa(sep, LV_OPA_COVER, 0);
      lv_obj_set_style_border_width(sep, 0, 0);
      lv_obj_set_style_radius(sep, 0, 0);
    }
  }

  /* status bar */
  lv_obj_t *sb = lv_obj_create(scr);
  lv_obj_set_pos(sb, 0, 453);
  lv_obj_set_size(sb, 480, 27);
  lv_obj_set_style_bg_color(sb, lv_color_hex(C_STATUS_BG), 0);
  lv_obj_set_style_bg_opa(sb, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(sb, 0, 0);
  lv_obj_set_style_radius(sb, 0, 0);
  lv_obj_set_style_pad_all(sb, 0, 0);
  lv_obj_clear_flag(sb, LV_OBJ_FLAG_SCROLLABLE);

  status_dot = lv_obj_create(sb);
  lv_obj_set_pos(status_dot, 20, 10);
  lv_obj_set_size(status_dot, 7, 7);
  lv_obj_set_style_radius(status_dot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(status_dot, lv_color_hex(C_MUTED), 0);
  lv_obj_set_style_bg_opa(status_dot, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(status_dot, 0, 0);

  status_left = make_label(sb, &lv_font_montserrat_12, C_MUTED, 34, 6, "connecting...");
  status_clock = make_label(sb, &lv_font_montserrat_12, C_MUTED, 440, 6, "");
}

/* Set one metric from parsed values. pct < 0 means idle/no data. */
static void set_metric(MetricW *m, int pct, const char *resets) {
  if (pct < 0) {
    lv_label_set_text(m->value, "-");
    lv_obj_set_style_text_color(m->value, lv_color_hex(C_IDLE), 0);
    lv_label_set_text(m->pct, "");
    lv_bar_set_value(m->bar, 0, LV_ANIM_OFF);
    lv_label_set_text(m->reset, "idle");
    lv_obj_set_style_text_color(m->reset, lv_color_hex(C_IDLE), 0);
    return;
  }
  uint32_t color = (pct >= 85) ? C_CRIT : (pct >= 60) ? C_WARN : C_SAND;
  uint32_t vcolor = (pct >= 85) ? C_CRIT : (pct >= 60) ? C_WARN : C_TEXT;
  lv_label_set_text_fmt(m->value, "%d", pct);
  lv_obj_set_style_text_color(m->value, lv_color_hex(vcolor), 0);
  lv_label_set_text(m->pct, "%");
  lv_obj_update_layout(m->value);
  lv_obj_align_to(m->pct, m->value, LV_ALIGN_OUT_RIGHT_BOTTOM, 2, -4);
  lv_bar_set_value(m->bar, pct, LV_ANIM_OFF);
  lv_obj_set_style_bg_color(m->bar, lv_color_hex(color), LV_PART_INDICATOR);
  lv_label_set_text(m->reset, resets && resets[0] ? resets : "");
  lv_obj_set_style_text_color(m->reset, lv_color_hex(C_RESET), 0);
}

static void apply_account(int i, JsonObject acc) {
  const char *name = acc["name"] | "?";
  const char *plan = acc["plan"] | "";
  char upper[24];
  snprintf(upper, sizeof(upper), "%s", name);
  for (char *p = upper; *p; p++) *p = toupper(*p);
  lv_label_set_text(ui[i].name, upper);
  lv_label_set_text(ui[i].plan, plan);
  lv_obj_update_layout(ui[i].name);
  lv_obj_align_to(ui[i].plan, ui[i].name, LV_ALIGN_OUT_RIGHT_BOTTOM, 8, 0);

  int spct = acc["session_pct"] | -1;
  int wpct = acc["weekly_pct"] | -1;
  set_metric(&ui[i].m[0], spct, acc["session_resets"] | "");
  set_metric(&ui[i].m[1], wpct, acc["weekly_resets"] | "");
  set_metric(&ui[i].m[2], acc["model_pct"] | -1, acc["model_resets"] | "");

  /* Celebrate on a reset (only on healthy data). Weekly wins over session if
   * both drop in the same poll. celebrate_*() ignores overlaps, so if several
   * accounts reset at once (e.g. weekly resets together) only the first shows. */
  if (strcmp(acc["status"] | "", "ok") == 0) {
    bool weekly_reset = prev_weekly_pct[i] > 0 && wpct >= 0 && wpct < prev_weekly_pct[i];
    bool session_reset = prev_session_pct[i] > 0 && spct < prev_session_pct[i];
    if (weekly_reset) {
      Serial.printf("[reset] weekly %s %d%%->%d%%\n", acc["name"] | "?", prev_weekly_pct[i], wpct);
      celebrate_weekly(i);
    } else if (session_reset) {
      Serial.printf("[reset] session %s %d%%->%d%%\n", acc["name"] | "?", prev_session_pct[i], spct);
      celebrate_session(i);
    }
    prev_session_pct[i] = spct;
    prev_weekly_pct[i] = wpct;
  }
}

/* Mirror the Mac's screen state: poll /display and drive the backlight. */
static bool backlight_on = true;
static uint32_t last_display_poll = 0;

static void poll_display_state() {
  String url = String(BRIDGE_URL);
  url.replace("/usage", "/display");
  HTTPClient http;
  http.setTimeout(3000);
  if (!http.begin(url)) return;
  if (http.GET() == 200) {
    bool want_on = (http.getString() != "off");
    if (want_on != backlight_on) {
      backlight_on = want_on;
      digitalWrite(GFX_BL, want_on ? HIGH : LOW);
      Serial.printf("[display] backlight %s\n", want_on ? "on" : "off");
    }
  }
  http.end();
}

static bool fetch_usage() {
  if (WiFi.status() != WL_CONNECTED) return false;
  HTTPClient http;
  http.setTimeout(8000);
  if (!http.begin(BRIDGE_URL)) return false;
  int code = http.GET();
  if (code != 200) {
    http.end();
    return false;
  }
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, http.getStream());
  http.end();
  if (err) return false;

  JsonArray accounts = doc["accounts"];
  int i = 0;
  for (JsonObject acc : accounts) {
    if (i >= N_ACCOUNTS) break;
    lv_obj_clear_flag(ui[i].row, LV_OBJ_FLAG_HIDDEN);
    apply_account(i++, acc);
  }
  /* Hide rows the feed no longer includes (e.g. dropping from 3 to 1 account)
   * and forget their history so a later reappearance doesn't false-celebrate. */
  for (int j = i; j < N_ACCOUNTS; j++) {
    lv_obj_add_flag(ui[j].row, LV_OBJ_FLAG_HIDDEN);
    prev_session_pct[j] = -2;
    prev_weekly_pct[j] = -2;
  }
  return i > 0;
}

static void update_status() {
  char buf[48];
  if (last_fetch_ok == 0) {
    snprintf(buf, sizeof(buf), WiFi.status() == WL_CONNECTED ? "connecting to bridge..." : "connecting to wifi...");
    lv_obj_set_style_bg_color(status_dot, lv_color_hex(C_MUTED), 0);
  } else {
    uint32_t age = (millis() - last_fetch_ok) / 1000;
    if (age < 90) {
#if SHOW_DATA_AGE
      snprintf(buf, sizeof(buf), "bridge ok - %lus ago", (unsigned long)age);
#else
      snprintf(buf, sizeof(buf), "bridge ok");
#endif
    } else {
      snprintf(buf, sizeof(buf), "STALE - %lum ago", (unsigned long)(age / 60));
    }
    bool stale = (millis() - last_fetch_ok) > STALE_MS;
    lv_obj_set_style_bg_color(status_dot, lv_color_hex(stale ? C_CRIT : C_OK_DOT), 0);
    lv_obj_set_style_text_color(status_left, lv_color_hex(stale ? C_WARN : C_MUTED), 0);
  }
  lv_label_set_text(status_left, buf);

  struct tm t;
  if (getLocalTime(&t, 0)) {
    char clk[8];
    strftime(clk, sizeof(clk), "%H:%M", &t);
    lv_label_set_text(status_clock, clk);
    lv_obj_update_layout(status_clock);
    lv_obj_set_x(status_clock, 480 - 20 - lv_obj_get_width(status_clock));
  }
}

/* ================= Mascot celebrations (captured Codrops animations) ========
 * Two triggers:
 *   - 5h session reset -> confetti GIF scaled into that account's SESSION cell
 *   - weekly reset     -> flag GIF full-screen with a caption
 * GIF backgrounds are the dashboard color, so opaque frames blend in. */

#define ROW_H 151           /* account row height (matches build_ui) */
#define SESSION_CELL_X 20   /* SESSION column x */
#define SESSION_CELL_W 136  /* metric column width */

static lv_obj_t *celeb_obj = NULL; /* active overlay (gif or fullscreen group) */
static uint32_t celeb_started = 0;
static const char *celeb_name = "";

static void celeb_done_cb(lv_timer_t *t) {
  (void)t;
  uint32_t ms = millis() - celeb_started;
  Serial.printf("[celeb] %s done: %u flushes in %u ms (~%.1f/s)\n", celeb_name,
                (unsigned)g_flushes, (unsigned)ms, ms ? g_flushes * 1000.0f / ms : 0);
  if (celeb_obj) lv_obj_del(celeb_obj);
  celeb_obj = NULL;
  g_gifx = g_gify = -1;
}

static void celeb_arm(uint32_t duration_ms) {
  g_flushes = g_frames = 0;
  celeb_started = millis();
  lv_timer_t *t = lv_timer_create(celeb_done_cb, duration_ms, NULL);
  lv_timer_set_repeat_count(t, 1);
}

/* 5h session reset: confetti over the SESSION cell of account `acct`. */
static void celebrate_session(int acct) {
  if (celeb_obj) return;
  celeb_name = "session";
  lv_coord_t ry = acct * ROW_H;

  lv_obj_t *g = lv_gif_create(lv_layer_top());
  lv_gif_set_src(g, &mascot_confetti_gif);
  lv_obj_update_layout(g);
  lv_coord_t gw = lv_obj_get_width(g), gh = lv_obj_get_height(g);
  lv_coord_t x = SESSION_CELL_X + (SESSION_CELL_W - gw) / 2;
  lv_coord_t y = ry + 40 + (108 - gh) / 2; /* center over the metric cell */
  lv_obj_set_pos(g, x, y);

  celeb_obj = g;
  g_gifx = x;
  g_gify = y;
  /* ends held on the standing pose (~2.5s play + 0.8s hold); remove mid-hold */
  celeb_arm(3000);
}

/* Weekly reset: full-screen flag hero + caption. */
static void celebrate_weekly(int acct) {
  if (celeb_obj) return;
  celeb_name = "weekly";

  lv_obj_t *ov = lv_obj_create(lv_layer_top());
  lv_obj_remove_style_all(ov);
  lv_obj_set_size(ov, 480, 480);
  lv_obj_set_pos(ov, 0, 0);
  lv_obj_set_style_bg_color(ov, lv_color_hex(C_BG), 0);
  lv_obj_set_style_bg_opa(ov, LV_OPA_COVER, 0);
  lv_obj_clear_flag(ov, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);

  lv_obj_t *g = lv_gif_create(ov);
  lv_gif_set_src(g, &mascot_flag_gif);
  lv_obj_align(g, LV_ALIGN_TOP_MID, 0, 70);

  /* account name (already uppercased by apply_account) in Claude orange */
  lv_obj_t *l1 = lv_label_create(ov);
  lv_obj_set_style_text_font(l1, &lv_font_montserrat_16, 0);
  lv_obj_set_style_text_color(l1, lv_color_hex(C_NAME), 0);
  lv_obj_set_style_text_letter_space(l1, 2, 0);
  lv_label_set_text(l1, lv_label_get_text(ui[acct].name));
  lv_obj_align(l1, LV_ALIGN_TOP_MID, 0, 380);

  lv_obj_t *l2 = lv_label_create(ov);
  lv_obj_set_style_text_font(l2, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_color(l2, lv_color_hex(C_SAND), 0);
  lv_label_set_text(l2, "weekly limit reset");
  lv_obj_align(l2, LV_ALIGN_TOP_MID, 0, 404);

  celeb_obj = ov;
  lv_obj_update_layout(g);
  g_gifx = lv_obj_get_x(g);
  g_gify = lv_obj_get_y(g);
  celeb_arm(4000);
}

void setup() {
  Serial.begin(115200);

  gfx->begin();
  gfx->fillScreen(BLACK);
  pinMode(GFX_BL, OUTPUT);
  digitalWrite(GFX_BL, HIGH);

  lv_init();
  /* Full-screen draw buffer in PSRAM: each redraw (incl. a whole GIF frame)
   * is composed once and flushed in a single draw call, so frames land in one
   * sweep instead of visible horizontal strips. */
  uint32_t buf_px = 480 * 480;
  buf1 = (lv_color_t *)heap_caps_malloc(buf_px * sizeof(lv_color_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!buf1) buf1 = (lv_color_t *)malloc(buf_px * sizeof(lv_color_t));
  lv_disp_draw_buf_init(&draw_buf, buf1, NULL, buf_px);

  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = 480;
  disp_drv.ver_res = 480;
  disp_drv.flush_cb = disp_flush;
  disp_drv.draw_buf = &draw_buf;
  lv_disp_drv_register(&disp_drv);

  build_ui();

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  /* Europe/Berlin with DST rules (matches the bridge's local time). */
  configTzTime("CET-1CEST,M3.5.0,M10.5.0/3", "pool.ntp.org", "time.google.com");
}

static uint32_t last_wifi_kick = 0;

void loop() {
  lv_timer_handler();

  uint32_t now = millis();

  /* WiFi watchdog: if not connected, re-kick association every 15s. */
  if (WiFi.status() != WL_CONNECTED) {
    if (now - last_wifi_kick >= 15000) {
      last_wifi_kick = now;
      Serial.printf("[wifi] status=%d, reconnecting to %s\n", WiFi.status(), WIFI_SSID);
      WiFi.disconnect();
      WiFi.begin(WIFI_SSID, WIFI_PASS);
    }
  } else if (last_wifi_kick != 0) {
    last_wifi_kick = 0;
    Serial.printf("[wifi] connected, ip=%s rssi=%d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
  }
  bool due = (last_fetch_try == 0) || (now - last_fetch_try >= POLL_MS);
  /* retry sooner while we have nothing on screen yet */
  if (last_fetch_ok == 0 && last_fetch_try != 0 && now - last_fetch_try >= 5000) due = true;

  if (due && WiFi.status() == WL_CONNECTED) {
    last_fetch_try = now;
    if (fetch_usage()) last_fetch_ok = millis();
  }

  if (WiFi.status() == WL_CONNECTED && now - last_display_poll >= 5000) {
    last_display_poll = now;
    poll_display_state();
  }

  if (now - last_status_tick >= 1000) {
    last_status_tick = now;
    update_status();
  }

  delay(5);
}
