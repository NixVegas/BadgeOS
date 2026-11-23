#include "bar.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static struct config config = {
    .count = 1,
    .apps = {{.id = "demo", .unit = "demo.service", .app_id = "badge-demo"}}
};

static unsigned step(struct state *s, enum event_type type, uint64_t now)
{
    return state_step(s, &config, (struct event){.type = type, .app = 0, .con_id = 42}, now);
}

static void running(struct state *s)
{
    state_init(s);
    assert(step(s, TAP_APP, 0) == START);
    assert(step(s, TAP_APP, 1) == 0);
    step(s, WINDOW_NEW, 2);
    state_step(s, &config, (struct event){.type = UNIT_CHANGED, .unit = {.active = true, .ready = true}}, 2);
    assert(state_app_ready(s) && s->con_id == 42);
}

static void lifecycle(void)
{
    struct state s;
    struct event inactive = {.type = UNIT_CHANGED, .app = 0};
    struct event active = {.type = UNIT_CHANGED, .app = 0, .unit = {.active = true}};

    running(&s);
    assert(step(&s, TAP_CLOSE, 3) == STOP);
    assert(step(&s, WINDOW_CLOSED, 4) == CHECK_UNIT);
    assert(state_step(&s, &config, active, 5) == 0 && s.phase == APP);
    assert(state_step(&s, &config, active, 2005) == 0 && s.phase == APP && s.unit.active);
    assert(state_step(&s, &config, inactive, 2006) == 0 && s.phase == HOME && s.app == -1);

    state_init(&s);
    step(&s, TAP_APP, 0);
    assert(step(&s, TICK, 30000) == 0 && s.phase == APP);
    struct event timedout = {.type = UNIT_CHANGED, .unit = {.failed = true, .result = "timeout"}};
    assert(state_step(&s, &config, timedout, 30001) == 0 && s.phase == HOME && strstr(s.error, "timeout"));
    step(&s, TAP_ERROR, 30002);
    step(&s, TICK, 35002);
    assert(!s.error[0]);
    struct unit_state pending;
    assert(unit_parse(&pending, "ActiveState=inactive\nJob=123\nResult=success\n"));
    assert(pending.active && !pending.ready);
    state_init(&s);
    step(&s, TAP_APP, 0);
    assert(step(&s, OP_FAILED, 1) == CHECK_UNIT);
    assert(state_step(&s, &config, inactive, 2) == 0 && s.phase == HOME && !s.unit.active && s.error[0]);

    uint64_t windows[MAX_APPS] = {42};
    struct unit_state units[MAX_APPS] = {{.active = true}};
    state_restore(&s, &config, windows, units);
    assert(s.phase == APP && s.con_id == 42);
    step(&s, WINDOW_CLOSED, 1);
    state_step(&s, &config, (struct event){.type = UNIT_CHANGED, .unit = {.failed = true}}, 2);
    assert(s.phase == HOME && s.error[0]);
    assert(step(&s, TAP_BACK, 3) == 0 && s.phase == HOME && s.error[0]);
}

static void settings(void)
{
    struct state s;
    config.setting_count = 1;
    strcpy(config.settings[0].id, "wifi");
    state_init(&s);
    assert(step(&s, TAP_SETTINGS, 0) == READ_SETTINGS);
    assert(step(&s, TAP_RADIOS, 1) == 0 && step(&s, TAP_SETTING, 1) == READ_SETTINGS && s.phase == SETTING);
    assert(step(&s, TAP_ENABLE, 2) == 0);
    state_step(&s, &config, (struct event){.type = SETTING_CHANGED}, 3);
    assert(step(&s, TAP_ENABLE, 4) == ENABLE_SETTING && s.setting_busy);
    state_step(&s, &config, (struct event){.type = SETTING_CHANGED,
        .setting_status = {.on = true}}, 5);
    assert(step(&s, TAP_DISABLE, 6) == DISABLE_SETTING);
    state_step(&s, &config, (struct event){.type = SETTING_FAILED, .error = "Stop failed"}, 7);
    assert(!s.setting_busy && s.error[0]);
    assert(step(&s, TAP_BACK, 8) == 0 && s.phase == RADIOS && step(&s, TAP_BACK, 8) == 0 && s.phase == SETTINGS);
}

static void app_controls(void)
{
    struct state s;
    config.apps[0].keyboard = true;
    running(&s);
    assert(step(&s, TAP_KEYBOARD, 3) == TOGGLE_KEYBOARD);
    assert(state_step(&s, &config, (struct event){.type = KEYBOARD_DONE}, 4) == 0 && !s.keyboard_busy && s.phase == APP);
    assert(step(&s, TAP_CLOSE, 5) == STOP && s.phase == APP);

    config.group_count = 1;
    strcpy(config.groups[0], "Games");
    strcpy(config.apps[0].group, "Games");
    state_init(&s);
    assert(step(&s, TAP_GROUP, 0) == 0 && s.phase == GROUP && step(&s, TAP_APP, 1) == START);
    step(&s, WINDOW_NEW, 2);
    step(&s, WINDOW_CLOSED, 3);
    assert(state_step(&s, &config, (struct event){.type = UNIT_CHANGED}, 4) == 0 && s.phase == GROUP);
}

static void display_size(void)
{
    struct state s;
    state_init(&s);
    step(&s, TAP_SETTINGS, 0);
    step(&s, TAP_DISPLAY, 1);
    /* Without a half mode the Display page holds Brightness alone. */
    assert(step(&s, TAP_DIM, 1) == DIM && step(&s, TAP_SIZE, 1) == 0 && s.phase == DISPLAY);
    s.half_mode = true;
    assert(step(&s, TAP_SIZE, 2) == 0 && s.phase == DISPLAY_SIZE);
    assert(step(&s, TAP_HALF, 3) == HALF_SIZE);
    assert(step(&s, TAP_FULL, 4) == 0);
    assert(step(&s, TAP_BACK, 5) == 0 && s.phase == DISPLAY_SIZE && s.display_busy);
    s.setting = 0; /* A radio read queued before entering Display size. */
    state_step(&s, &config, (struct event){.type=SETTING_CHANGED, .app=0}, 6);
    step(&s, SETTING_FAILED, 6);
    step(&s, OP_FAILED, 6);
    assert(s.display_busy && step(&s, TAP_FULL, 6) == 0);
    assert(step(&s, TAP_BACK, 6) == 0 && s.phase == DISPLAY_SIZE);
    step(&s, DISPLAY_DONE, 6);
    assert(step(&s, TAP_FULL, 7) == FULL_SIZE);
    step(&s, DISPLAY_DONE, 8);
    step(&s, OP_FAILED, 8);
    assert(s.error[0] && !s.display_busy);
    assert(step(&s, TAP_BACK, 9) == 0 && s.phase == DISPLAY && !s.display_busy);
    assert(step(&s, TAP_BACK, 10) == 0 && s.phase == SETTINGS);
}

static void core_switch(void)
{
    struct state s;
    config.core_reboot = true;
    state_init(&s);
    step(&s, TAP_SETTINGS, 0);
    s.current_core = CORE_ARM;
    assert(step(&s, TAP_CORE, 1) == 0 && s.phase == CORE);
    assert(step(&s, TAP_RISCV, 2) == 0 && s.phase == CORE_CONFIRM && s.target_core == CORE_RISCV);
    assert(step(&s, TAP_REBOOT, 3) == REBOOT_CORE);
    assert(step(&s, TAP_REBOOT, 4) == 0);
    assert(step(&s, REBOOT_FAILED, 5) == 0 && s.phase == CORE && !s.reboot_busy);
}

/* One app per letter, grouped by the letter. */
static bool load(const char *groups)
{
    struct config c;
    FILE *f = fopen("state-test.json", "w");
    fputs("{\"output\":\"o\",\"backlight\":\"b\",\"font\":\"f\",\"bar_height\":48,\"font_size\":14,\"apps\":[", f);
    for (int i = 0; groups[i]; i++)
        fprintf(f, "%s{\"id\":\"a%d\",\"label\":\"A\",\"unit\":\"a%d.service\",\"app_id\":\"a%d\",\"group\":\"%c\"}",
                i ? "," : "", i, i, i, groups[i]);
    return fputs("]}", f) >= 0 && fclose(f) == 0 && config_load(&c, "state-test.json");
}

int main(void)
{
    lifecycle();
    settings();
    app_controls();
    display_size();
    core_switch();
    /* Home holds three groups and Settings; a group holds three apps and Back. */
    assert(load("GGDDTTT") && !load("GDTX") && !load("GGGGD"));
    puts("state transitions passed");
    return 0;
}
