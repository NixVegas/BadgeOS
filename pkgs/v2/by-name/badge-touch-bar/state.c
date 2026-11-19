#include "bar.h"
#include <stdio.h>
#include <string.h>

bool state_app_ready(const struct state *s) {
    return s->phase == APP && s->window && s->unit.ready && !s->unit.stopping;
}

void state_init(struct state *s) {
    memset(s, 0, sizeof(*s));
    s->app = s->setting = s->group = -1;
    s->revision = 1;
}

static void home(struct state *s) {
    s->phase = s->group < 0 ? HOME : GROUP;
    s->app = -1;
    s->con_id = s->deadline = 0;
    s->window = s->keyboard_busy = false;
    memset(&s->unit, 0, sizeof(s->unit));
}

static void fail(struct state *s, const char *reason) {
    s->deadline = 0;
    snprintf(s->error, sizeof(s->error), "%s", reason);
}

static void app_error(struct state *s, const struct config *c, const char *reason) {
    char text[TEXT_LEN];
    snprintf(text, sizeof(text), "%s: %s", c->apps[s->app].label, reason);
    int app = s->app;
    home(s);
    s->app = app; /* Keep the error badge on its app until tapped. */
    fail(s, text);
}

unsigned state_step(struct state *s, const struct config *c, struct event e, uint64_t now) {
    struct state before = *s;
    unsigned effects = 0;
    if (s->reboot_busy && e.type != REBOOT_FAILED && e.type != TICK) return 0;
    switch (e.type) {
    case TAP_APP:
        if ((s->phase != HOME && s->phase != GROUP) || s->unit.active || s->window ||
            e.app < 0 || e.app >= c->count) break;
        if (!c->apps[e.app].hidden && app_group(c, e.app) != s->group) break;
        home(s);
        s->app = e.app;
        s->phase = APP;
        s->unit.active = true; /* Reserve the slot until the start result is known. */
        effects = START;
        break;
    case TAP_GROUP:
        if (s->phase == HOME && !s->unit.active && !s->window &&
            e.app >= 0 && e.app < c->group_count) {
            s->group = e.app;
            home(s);
        }
        break;
    case TAP_CLOSE:
        if (!state_app_ready(s)) break;
        s->unit.stopping = true;
        effects = STOP;
        break;
    case TAP_KEYBOARD:
        if (state_app_ready(s) && s->app >= 0 && c->apps[s->app].keyboard && !s->keyboard_busy) {
            s->keyboard_busy = true;
            effects = TOGGLE_KEYBOARD;
        }
        break;
    case KEYBOARD_DONE:
        if (e.app == s->app) {
            s->keyboard_busy = false;
            if (e.error) snprintf(s->error, sizeof(s->error), "%s", e.error);
        }
        break;
    case TAP_SETTINGS:
        if (s->phase == HOME && !s->unit.active && !s->window) {
            s->phase = SETTINGS;
            memset(s->setting_known, 0, sizeof(s->setting_known));
            if (c->setting_count) effects = READ_SETTINGS;
        }
        break;
    case TAP_BACK:
        if (s->phase == GROUP && !s->unit.active && !s->window) {
            s->group = -1;
            home(s);
        }
        else if (s->phase == SETTINGS) s->phase = HOME;
        else if (s->phase == DISPLAY_SIZE && !s->display_busy) { s->phase = DISPLAY; s->error[0] = 0; }
        else if ((s->phase == DISPLAY || s->phase == RADIOS) && !s->setting_busy)
            s->phase = SETTINGS;
        else if (s->phase == SETTING && !s->setting_busy) s->phase = RADIOS;
        else if (s->phase == CORE_CONFIRM) { s->phase = CORE; s->deadline = 0; }
        else if (s->phase == CORE) { s->phase = SETTINGS; s->error[0] = 0; }
        break;
    case TAP_SIZE:
        if (s->phase == DISPLAY && s->half_mode) s->phase = DISPLAY_SIZE;
        break;
    case TAP_FULL: case TAP_HALF:
        if (s->phase == DISPLAY_SIZE && !s->display_busy) {
            s->display_busy = true;
            effects = e.type == TAP_FULL ? FULL_SIZE : HALF_SIZE;
        }
        break;
    case DISPLAY_DONE:
        s->display_busy = false;
        break;
    case TAP_CORE:
        if (s->phase == SETTINGS && c->core_reboot) { s->phase = CORE; s->error[0] = 0; }
        break;
    case TAP_ARM: case TAP_RISCV:
        if (s->phase == CORE && c->core_reboot && s->current_core != CORE_UNKNOWN) {
            s->target_core = e.type == TAP_ARM ? CORE_ARM : CORE_RISCV;
            s->phase = CORE_CONFIRM;
            s->error[0] = 0;
            s->deadline = now + 15000;
        }
        break;
    case TAP_REBOOT:
        if (s->phase == CORE_CONFIRM && c->core_reboot && now < s->deadline &&
            (s->target_core == CORE_ARM || s->target_core == CORE_RISCV)) {
            s->reboot_busy = true;
            /* The worker owns the timeout, including time spent queued. */
            s->deadline = 0;
            effects = REBOOT_CORE;
        }
        break;
    case REBOOT_FAILED:
        s->reboot_busy = false;
        s->phase = CORE;
        s->deadline = 0;
        snprintf(s->error, sizeof(s->error), "%s", e.error ? e.error : "Reboot failed");
        break;
    case TAP_DISPLAY:
        if (s->phase == SETTINGS) s->phase = DISPLAY;
        break;
    case TAP_RADIOS:
        if (s->phase == SETTINGS && c->setting_count) s->phase = RADIOS;
        break;
    case TAP_SETTING:
        if (s->phase == RADIOS && e.app >= 0 && e.app < c->setting_count) {
            s->setting = e.app;
            s->error[0] = 0;
            s->phase = SETTING;
            s->setting_known[e.app] = false;
            effects = READ_SETTINGS;
        }
        break;
    case TAP_ENABLE: case TAP_DISABLE:
        if (s->phase == SETTING && !s->setting_busy && s->setting >= 0 &&
            s->setting_known[s->setting] && s->setting_status[s->setting].on == (e.type == TAP_DISABLE)) {
            s->setting_busy = true;
            s->error[0] = 0;
            effects = e.type == TAP_ENABLE ? ENABLE_SETTING : DISABLE_SETTING;
        }
        break;
    case TAP_JOIN:
        if (s->phase == SETTING && !s->setting_busy && s->setting >= 0 &&
            s->setting_known[s->setting] && s->setting_status[s->setting].join &&
            c->settings[s->setting].join_app >= 0) {
            int app = c->settings[s->setting].join_app;
            s->group = -1;
            home(s);
            effects = state_step(s, c, (struct event){.type=TAP_APP, .app=app}, now);
        }
        break;
    case SETTING_CHANGED:
        if (e.app >= 0 && e.app < c->setting_count) {
            s->setting_known[e.app] = true;
            s->setting_status[e.app] = e.setting_status;
            if (e.app == s->setting) s->setting_busy = false;
        }
        break;
    case SETTING_FAILED:
        s->setting_busy = false;
        if (e.app >= 0 && e.app < c->setting_count) s->setting_known[e.app] = false;
        snprintf(s->error, sizeof(s->error), "%s", e.error ? e.error : "Setting failed");
        effects = READ_SETTINGS; /* Bring the toggle back, so that a second tap retries. */
        break;
    case TAP_DIM: case TAP_BRIGHT:
        if (s->phase == DISPLAY) effects = e.type == TAP_DIM ? DIM : BRIGHT;
        break;
    case TAP_ERROR:
        if (s->error[0] && (s->phase != APP || state_app_ready(s))) {
            s->return_phase = s->phase;
            s->phase = ERROR_SHOWN;
            s->deadline = now + 5000;
        }
        break;
    case WINDOW_NEW:
        if (e.app == s->app && s->phase == APP) {
            s->con_id = e.con_id;
            s->window = true;
            effects = CHECK_UNIT;
        }
        break;
    case WINDOW_CLOSED:
        if (s->app < 0 || e.con_id != s->con_id) break;
        s->window = false;
        effects = CHECK_UNIT;
        break;
    case UNIT_CHANGED:
        if (e.app != s->app || s->app < 0) break;
        bool stopping = s->unit.stopping && e.unit.pending;
        s->unit = e.unit;
        s->unit.stopping |= stopping;
        if (!s->unit.active && !s->window) {
            if (e.unit.failed) app_error(s, c, e.unit.result[0] ? e.unit.result : "failed");
            else home(s);
        }
        break;
    case OP_FAILED:
        s->setting_busy = false;
        if (s->phase == APP) effects = CHECK_UNIT;
        fail(s, e.error ? e.error : "Operation failed");
        break;
    case TICK:
        if (s->deadline && now >= s->deadline) {
            s->deadline = 0;
            if (s->phase == ERROR_SHOWN) {
                s->phase = s->return_phase;
                s->error[0] = 0;
            }
            else if (s->phase == CORE_CONFIRM) s->phase = CORE;
        }
        break;
    }
    if (memcmp(&before, s, sizeof(*s)) || (effects & (DIM | BRIGHT))) s->revision++;
    return effects;
}

void state_restore(struct state *s, const struct config *c, const uint64_t *windows,
                   const struct unit_state *units) {
    if (s->reboot_busy) return;
    int selected = -1;
    for (int i = 0; i < c->count; i++) {
        if (windows[i] || units[i].active) {
            if (selected < 0 || i == s->app) selected = i;
        }
    }
    home(s);
    if (selected >= 0) {
        s->group = app_group(c, selected);
        s->app = selected;
        s->con_id = windows[selected];
        s->window = s->con_id != 0;
        s->unit = units[selected];
        s->phase = APP;
    } else {
        for (int i = 0; i < c->count; i++) if (units[i].failed) {
            s->group = app_group(c, i);
            s->app = i;
            app_error(s, c, units[i].result[0] ? units[i].result : "failed");
            break;
        }
    }
    s->revision++;
}
