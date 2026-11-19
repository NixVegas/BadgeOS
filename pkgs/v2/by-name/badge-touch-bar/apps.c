#include "bar.h"
#include <ctype.h>
#include <stdio.h>
#include <string.h>

const char *json_string(json_object *o, const char *key) {
    json_object *v;
    return json_object_object_get_ex(o, key, &v) && json_object_is_type(v, json_type_string)
        ? json_object_get_string(v) : "";
}

static bool field(char *dest, size_t size, json_object *o, const char *key) {
    const char *text = json_string(o, key);
    if (!*text || strlen(text) >= size) return false;
    memcpy(dest, text, strlen(text) + 1);
    return true;
}

static bool identifier(const char *s, bool unit) {
    if (!isalnum((unsigned char)*s)) return false;
    for (; *s; s++) if (!isalnum((unsigned char)*s) && *s != '-' && *s != '_' &&
                        !(unit && (*s == '.' || *s == '@'))) return false;
    return true;
}

bool config_load(struct config *c, const char *path) {
    memset(c, 0, sizeof(*c));
    json_object *o = json_object_from_file(path), *apps, *v;
    bool ok = false;
    if (!o || !field(c->output, sizeof(c->output), o, "output") ||
        !json_object_object_get_ex(o, "apps", &apps) || !json_object_is_type(apps, json_type_array)) goto out;
    field(c->backlight, sizeof(c->backlight), o, "backlight"); /* Optional: no Brightness without it. */
    size_t n = json_object_array_length(apps);
    if (n > MAX_APPS) goto out;
    for (size_t i = 0; i < n; i++) {
        json_object *entry = json_object_array_get_idx(apps, i);
        struct app *a = &c->apps[i];
        if (!field(a->id, sizeof(a->id), entry, "id") || !identifier(a->id, false) ||
            !field(a->label, sizeof(a->label), entry, "label") ||
            !field(a->unit, sizeof(a->unit), entry, "unit") || !identifier(a->unit, true) ||
            !field(a->app_id, sizeof(a->app_id), entry, "app_id")) goto out;
        size_t len = strlen(a->unit);
        if (len < 9 || strcmp(a->unit + len - 8, ".service")) goto out;
        a->keyboard = *json_string(entry, "keyboard_unit");
        if (json_object_object_get_ex(entry, "system", &v)) {
            if (!json_object_is_type(v, json_type_boolean)) goto out;
            a->system = json_object_get_boolean(v);
        }
        if (a->system && a->keyboard) goto out;
        if (a->keyboard) {
            if (!field(a->keyboard_unit, sizeof(a->keyboard_unit), entry, "keyboard_unit") ||
                !identifier(a->keyboard_unit, true)) goto out;
            size_t length = strlen(a->keyboard_unit);
            if (length < 9 || strcmp(a->keyboard_unit + length - 8, ".service")) goto out;
        }
        a->hidden = json_object_object_get_ex(entry, "hidden", &v) && json_object_get_boolean(v);
        const char *group = json_string(entry, "group");
        if (*group) {
            if (!field(a->group, sizeof(a->group), entry, "group") || !identifier(group, false) || a->hidden) goto out;
            int g;
            for (g = 0; g < c->group_count; g++) if (!strcmp(group, c->groups[g])) break;
            if (g == c->group_count) {
                if (g == 3) goto out;
                strcpy(c->groups[c->group_count++], group);
            }
        }
        for (size_t j = 0; j < i; j++)
            if (!strcmp(a->id, c->apps[j].id) || !strcmp(a->app_id, c->apps[j].app_id) ||
                !strcmp(a->unit, c->apps[j].unit)) goto out;
    }
    c->count = (int)n;
    int home_count = 1 + c->group_count, group_sizes[3] = {0};
    for (int i = 0; i < c->count; i++) {
        if (c->apps[i].hidden) continue;
        int g = app_group(c, i);
        if (g < 0) home_count++;
        else if (++group_sizes[g] > 3) goto out;
    }
    if (home_count > 4) goto out;
    if (json_object_object_get_ex(o, "settings", &v)) {
        if (!json_object_is_type(v, json_type_array) || json_object_array_length(v) > MAX_SETTINGS) goto out;
        c->setting_count = (int)json_object_array_length(v);
        for (int i = 0; i < c->setting_count; i++) {
            json_object *entry = json_object_array_get_idx(v, i);
            struct setting *setting = &c->settings[i];
            setting->join_app = -1;
            if (!field(setting->id, sizeof(setting->id), entry, "id") || !identifier(setting->id, false) ||
                !field(setting->label, sizeof(setting->label), entry, "label") ||
                !field(setting->join_label, sizeof(setting->join_label), entry, "join_label") ||
                !field(setting->unit, sizeof(setting->unit), entry, "unit") || !identifier(setting->unit, true)) goto out;
            size_t len = strlen(setting->unit);
            if (len < 9 || strcmp(setting->unit + len - 8, ".service")) goto out;
            if (!field(setting->status_command, sizeof(setting->status_command), entry, "status_command") ||
                setting->status_command[0] != '/' ||
                !field(setting->stop_command, sizeof(setting->stop_command), entry, "stop_command") ||
                setting->stop_command[0] != '/') goto out;
            const char *join = json_string(entry, "join_app");
            if (*join) {
                for (int j = 0; j < c->count; j++)
                    if (!strcmp(join, c->apps[j].id)) setting->join_app = j;
                if (setting->join_app < 0) goto out;
            }
            for (int j = 0; j < i; j++)
                if (!strcmp(setting->id, c->settings[j].id)) goto out;
        }
    }
    ok = true;
out:
    if (o) json_object_put(o);
    if (!ok) fprintf(stderr, "badge-touch-bar: invalid app configuration\n");
    return ok;
}

int app_find(const struct config *c, const char *app_id) {
    for (int i = 0; i < c->count; i++) if (!strcmp(c->apps[i].app_id, app_id)) return i;
    return -1;
}

int app_group(const struct config *c, int app) {
    for (int i = 0; i < c->group_count; i++)
        if (!strcmp(c->apps[app].group, c->groups[i])) return i;
    return -1;
}
