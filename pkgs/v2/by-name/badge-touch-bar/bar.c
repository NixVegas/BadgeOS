#include "bar.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Rule each button along its top and its bottom only, and leave a gutter between the
 * buttons. swaybar answers a tap inside a block's min_width but draws the block
 * min_width wide plus the border and a 3 px margin for each side it rules, so a left or
 * a right rule puts drawn pixels where no tap reaches. A top and a bottom rule cost
 * nothing, taking their length from the width the block already has, and a gutter falls
 * between two blocks instead of inside one. */
#define GUTTER 4

static void block(json_object *rows, const struct state *s, const char *action,
                  const char *label, int width, bool enabled, bool busy, bool error) {
    json_object *o = json_object_new_object();
    char revision[32];
    snprintf(revision, sizeof(revision), "%" PRIu64, s->revision);
    json_object_object_add(o, "name", json_object_new_string(enabled ? action : "disabled"));
    json_object_object_add(o, "instance", json_object_new_string(revision));
    json_object_object_add(o, "full_text", json_object_new_string(label));
    json_object_object_add(o, "min_width", json_object_new_int(width > GUTTER ? width - GUTTER : 1));
    json_object_object_add(o, "align", json_object_new_string("center"));
    /* swaybar would draw its own separator 6 px past the gutter, so leave the gutter bare. */
    json_object_object_add(o, "separator", json_object_new_boolean(false));
    json_object_object_add(o, "separator_block_width", json_object_new_int(GUTTER));
    json_object_object_add(o, "color", json_object_new_string(busy ? "#101015" : enabled || error ? "#ffffff" : "#888888"));
    json_object_object_add(o, "background", json_object_new_string(error ? "#a02020" : busy ? "#ffffff" : "#101015"));
    json_object_object_add(o, "border", json_object_new_string("#666666"));
    json_object_object_add(o, "border_top", json_object_new_int(1));
    json_object_object_add(o, "border_bottom", json_object_new_int(1));
    json_object_object_add(o, "border_left", json_object_new_int(0));
    json_object_object_add(o, "border_right", json_object_new_int(0));
    json_object_array_add(rows, o);
}

/* The last block is the rightmost, which has no gutter and so keeps its own width. */
static void widen_last(json_object *rows) {
    size_t n = json_object_array_length(rows);
    json_object *last, *min;
    if (!n) return;
    last = json_object_array_get_idx(rows, n - 1);
    if (json_object_object_get_ex(last, "min_width", &min))
        json_object_object_add(last, "min_width", json_object_new_int(json_object_get_int(min) + GUTTER));
}

void bar_render(const struct state *s, const struct config *c, int width, bool ready) {
    json_object *rows = json_object_new_array();
    int usable = width > 0 ? width : 1;
    if (!ready) {
        block(rows, s, "disabled", width ? "Connecting…" : "Waiting for display…", usable, false, false, false);
    } else if (s->phase == APP && s->con_id) {
        bool running = state_app_ready(s);
        bool closing = s->unit.stopping || !s->window;
        bool keyboard = running && s->app >= 0 && c->apps[s->app].keyboard;
        int n = 1 + keyboard + (s->error[0] && running ? 1 : 0), part = usable / n;
        if (keyboard) block(rows, s, "keyboard", s->keyboard_busy ? "Keyboard…" : "Keyboard", part,
                            !s->keyboard_busy, s->keyboard_busy, false);
        block(rows, s, "close", running ? "Close" : closing ? "Closing…" : "Opening…", part,
              running, !running, false);
        if (s->error[0] && running) block(rows, s, "error", "!", usable - (n - 1) * part, true, false, true);
    } else if (s->phase == APP && s->app >= 0 && c->apps[s->app].hidden) {
        block(rows, s, "disabled", "Opening…", usable, false, true, false);
    } else if (s->phase == ERROR_SHOWN) {
        block(rows, s, "disabled", s->error, usable, false, false, true);
    } else if (s->phase == DISPLAY_SIZE) {
        int part = usable / 3;
        block(rows, s, "full", "Full", part, !s->display_busy, !s->half_size, false);
        block(rows, s, "half", "Half", part, !s->display_busy, s->half_size, false);
        block(rows, s, s->error[0] ? "error" : "back", s->error[0] ? "!" : "Back",
              usable - part * 2, !s->display_busy, false, s->error[0]);
    } else if (s->phase == CORE_CONFIRM) {
        if (s->reboot_busy) block(rows, s, "disabled", "Rebooting…", usable, false, true, false);
        else {
            int part = usable / 4;
            block(rows, s, "disabled", s->target_core == CORE_ARM ? "Reboot to ARM?" : "Reboot to RISC-V?",
                  part * 2, false, false, false);
            block(rows, s, "back", "Cancel", part, true, false, false);
            block(rows, s, "reboot", "Reboot", usable - part * 3, true, false, false);
        }
    } else if (s->phase == CORE) {
        int part = usable / 4;
        block(rows, s, "error", s->error[0] ? "Failed · !" : s->current_core == CORE_ARM ? "Now: ARM" :
              s->current_core == CORE_RISCV ? "Now: RISC-V" : "Unknown core", part, s->error[0], false, s->error[0]);
        block(rows, s, "core-arm", "ARM", part, s->current_core != CORE_UNKNOWN, false, false);
        block(rows, s, "core-riscv", "RISC-V", part, s->current_core != CORE_UNKNOWN, false, false);
        block(rows, s, "back", "Back", usable - part * 3, true, false, false);
    } else if (s->phase == SETTING) {
        int i = s->setting;
        const struct setting_status *status = &s->setting_status[i];
        bool known = s->setting_known[i];
        bool join = known && status->join && c->settings[i].join_app >= 0;
        int n = 4 + 2 * known + 2 * join, part = usable / n;
        const char *label = s->setting_busy ? "Working…" : s->error[0] ? "Failed · !" :
                            !s->setting_known[i] ? "Checking…" : status->label;
        block(rows, s, "error", label, part * 3, s->error[0] && !s->setting_busy, s->setting_busy, s->error[0]);
        if (known) block(rows, s, status->on ? "disable" : "enable",
                             status->on ? "Turn off" : "Turn on", part * 2, !s->setting_busy, false, false);
        if (join) block(rows, s, "join", c->settings[i].join_label, part * 2, !s->setting_busy, false, false);
        block(rows, s, "back", "Back", usable - (n - 1) * part, !s->setting_busy, false, false);
    } else if (s->phase == SETTINGS) {
        bool display = c->backlight[0] || s->half_mode;
        int n = 1 + display + (c->setting_count > 0) + c->core_reboot, part = usable / n;
        if (display) block(rows, s, "display", "Display", part, true, false, false);
        if (c->setting_count) block(rows, s, "radios", "Radios", part, true, false, false);
        if (c->core_reboot) block(rows, s, "core", "Core", part, true, false, false);
        block(rows, s, "back", "Back", usable - (n - 1) * part, true, false, false);
    } else if (s->phase == RADIOS) {
        int n = c->setting_count + 1, part = usable / n;
        for (int i = 0; i < c->setting_count; i++) {
            char action[80];
            snprintf(action, sizeof(action), "setting:%s", c->settings[i].id);
            block(rows, s, action, c->settings[i].label, part, true, false, false);
        }
        block(rows, s, "back", "Back", usable - (n - 1) * part, true, false, false);
    } else if (s->phase == DISPLAY) {
        bool light = c->backlight[0];
        int n = 1 + 4 * light + 2 * s->half_mode, part = usable / n;
        if (light) block(rows, s, "dim", "Brightness −", part * 2, true, false, false);
        if (light) block(rows, s, "bright", "Brightness +", part * 2, true, false, false);
        if (s->half_mode) block(rows, s, "size", "Display size", part * 2, true, false, false);
        block(rows, s, "back", "Back", usable - (n - 1) * part, true, false, false);
    } else {
        bool busy = s->phase == APP;
        int visible = 0;
        for (int i = 0; i < c->count; i++)
            if (!c->apps[i].hidden && app_group(c, i) == s->group) visible++;
        if (s->group < 0) visible += c->group_count;
        int n = visible + 1, part = usable / n;
        for (int i = 0; i < c->count; i++) {
            if (c->apps[i].hidden || app_group(c, i) != s->group) continue;
            char action[80], label[80];
            snprintf(action, sizeof(action), "app:%s", c->apps[i].id);
            snprintf(label, sizeof(label), "%s%s", c->apps[i].label, busy && i == s->app ? "…" : "");
            bool error = s->error[0] && !busy && i == s->app;
            if (error) snprintf(label, sizeof(label), "%s · !", c->apps[i].label);
            block(rows, s, error ? "error" : action, label, part,
                  error || (!busy && !s->unit.active && !s->window),
                  busy && i == s->app, error);
        }
        if (s->group < 0) for (int i = 0; i < c->group_count; i++) {
            char action[80];
            snprintf(action, sizeof(action), "group:%s", c->groups[i]);
            block(rows, s, action, c->groups[i], part, !busy && !s->unit.active && !s->window, false, false);
        }
        bool error = s->error[0] && !busy && (s->app < 0 || c->apps[s->app].hidden);
        block(rows, s, error ? "error" : s->group < 0 ? "settings" : "back",
              error ? "Settings · !" : s->group < 0 ? "Settings" : "Back",
              usable - (n - 1) * part, error || (!busy && !s->unit.active && !s->window), false, error);
    }
    widen_last(rows);
    printf("%s,\n", json_object_to_json_string_ext(rows, JSON_C_TO_STRING_PLAIN));
    fflush(stdout);
    json_object_put(rows);
}

bool bar_click(json_object *click, const struct state *s, const struct config *c, struct event *e) {
    json_object *button;
    if (!json_object_object_get_ex(click, "button", &button) || json_object_get_int(button) != 1) return false;
    const char *instance = json_string(click, "instance"), *name = json_string(click, "name");
    char *end;
    errno = 0;
    uint64_t revision = strtoull(instance, &end, 10);
    if (errno || end == instance || *end || revision != s->revision) return false;
    memset(e, 0, sizeof(*e));
    e->app = -1;
    const struct { const char *name; enum event_type type; } actions[] = {
        {"close", TAP_CLOSE}, {"settings", TAP_SETTINGS}, {"back", TAP_BACK},
        {"error", TAP_ERROR}, {"dim", TAP_DIM}, {"bright", TAP_BRIGHT},
        {"display", TAP_DISPLAY}, {"radios", TAP_RADIOS}, {"enable", TAP_ENABLE}, {"disable", TAP_DISABLE},
        {"join", TAP_JOIN}, {"keyboard", TAP_KEYBOARD},
        {"size", TAP_SIZE}, {"full", TAP_FULL}, {"half", TAP_HALF},
        {"core", TAP_CORE}, {"core-arm", TAP_ARM},
        {"core-riscv", TAP_RISCV}, {"reboot", TAP_REBOOT}
    };
    for (size_t i = 0; i < sizeof(actions)/sizeof(actions[0]); i++)
        if (!strcmp(name, actions[i].name)) { e->type = actions[i].type; return true; }
    if (!strncmp(name, "app:", 4)) for (int i = 0; i < c->count; i++)
        if (!strcmp(name + 4, c->apps[i].id)) { e->type = TAP_APP; e->app = i; return true; }
    if (!strncmp(name, "setting:", 8)) for (int i = 0; i < c->setting_count; i++)
        if (!strcmp(name + 8, c->settings[i].id)) { e->type = TAP_SETTING; e->app = i; return true; }
    if (!strncmp(name, "group:", 6)) for (int i = 0; i < c->group_count; i++)
        if (!strcmp(name + 6, c->groups[i])) { e->type = TAP_GROUP; e->app = i; return true; }
    return false;
}
