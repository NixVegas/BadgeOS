#ifndef BADGE_TOUCH_BAR_H
#define BADGE_TOUCH_BAR_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <json-c/json.h>

#define MAX_APPS 16
#define MAX_SETTINGS 2
#define TEXT_LEN 160
struct app {
    char id[64], label[64], unit[128], app_id[128], keyboard_unit[128], group[64];
    bool keyboard, hidden, system;
};
struct setting { char id[64], label[64], join_label[64], unit[128], status_command[512], stop_command[512]; int join_app; };
struct setting_status { bool on, join; char label[TEXT_LEN]; };
struct config {
    struct app apps[MAX_APPS];
    int count, setting_count;
    char groups[3][64];
    int group_count;
    struct setting settings[MAX_SETTINGS];
    char output[128], backlight[512];
};
struct unit_state { bool active, ready, stopping, pending, failed; char result[32]; };
struct output { int width; };
enum phase { HOME, GROUP, APP, SETTINGS, DISPLAY, RADIOS, SETTING, ERROR_SHOWN };
enum event_type {
    TAP_APP, TAP_GROUP, TAP_CLOSE, TAP_SETTINGS, TAP_BACK, TAP_ERROR, TAP_DIM, TAP_BRIGHT,
    TAP_DISPLAY, TAP_RADIOS, TAP_SETTING, TAP_ENABLE, TAP_DISABLE, TAP_JOIN, SETTING_CHANGED, SETTING_FAILED, TAP_KEYBOARD, KEYBOARD_DONE,
    WINDOW_NEW, WINDOW_CLOSED, UNIT_CHANGED, OP_FAILED, TICK
};
enum effect { START = 1, STOP = 2, CHECK_UNIT = 4, DIM = 8, BRIGHT = 16, READ_SETTINGS = 32, ENABLE_SETTING = 64, TOGGLE_KEYBOARD = 128, DISABLE_SETTING = 256 };
struct event {
    enum event_type type;
    int app;
    uint64_t con_id;
    struct unit_state unit;
    struct setting_status setting_status;
    const char *error;
};
struct state {
    enum phase phase, return_phase;
    int app, setting, group;
    bool setting_known[MAX_SETTINGS], setting_busy;
    struct setting_status setting_status[MAX_SETTINGS];
    uint64_t con_id, revision, deadline;
    bool window, keyboard_busy;
    struct unit_state unit;
    char error[TEXT_LEN];
};
bool state_app_ready(const struct state *s);
void state_init(struct state *s);
unsigned state_step(struct state *s, const struct config *c, struct event e, uint64_t now);
void state_restore(struct state *s, const struct config *c, const uint64_t *windows,
                   const struct unit_state *units);

bool config_load(struct config *c, const char *path);
int app_find(const struct config *c, const char *app_id);
int app_group(const struct config *c, int app);
const char *json_string(json_object *o, const char *key);
void sway_windows(json_object *tree, const struct config *c, uint64_t *windows);
struct output sway_output(json_object *outputs, const char *name);
bool unit_parse(struct unit_state *u, const char *text);
bool setting_parse(struct setting_status *s, const char *text);
bool brightness_step(const char *path, int change);
void bar_render(const struct state *s, const struct config *c, int width, bool ready);
bool bar_click(json_object *click, const struct state *s, const struct config *c, struct event *e);

struct process {
    pid_t pid;
    int fd, status;
    bool exited;
    char *data;
    size_t len, capacity;
};
bool process_start(struct process *p, char *const argv[]);
bool process_read(struct process *p);
bool process_done(struct process *p);
void process_clear(struct process *p);
#endif
