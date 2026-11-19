#include "bar.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

void sway_windows(json_object *tree, const struct config *c, uint64_t *windows) {
    if (!tree || !json_object_is_type(tree, json_type_object)) return;
    int app = app_find(c, json_string(tree, "app_id"));
    json_object *v;
    if (app >= 0 && !windows[app] && json_object_object_get_ex(tree, "id", &v))
        windows[app] = json_object_get_uint64(v);
    const char *keys[] = { "nodes", "floating_nodes" };
    for (size_t k = 0; k < 2; k++) if (json_object_object_get_ex(tree, keys[k], &v) && json_object_is_type(v, json_type_array))
        for (size_t i = 0; i < json_object_array_length(v); i++)
            sway_windows(json_object_array_get_idx(v, i), c, windows);
}

static int number(json_object *o, const char *key) {
    json_object *v;
    return json_object_object_get_ex(o, key, &v) ? json_object_get_int(v) : 0;
}

struct output sway_output(json_object *outputs, const char *name) {
    struct output out = {0};
    if (!outputs || !json_object_is_type(outputs, json_type_array)) return out;
    for (size_t i = 0; i < json_object_array_length(outputs); i++) {
        json_object *o = json_object_array_get_idx(outputs, i), *active, *rect;
        if (strcmp(json_string(o, "name"), name) ||
            !json_object_object_get_ex(o, "active", &active) || !json_object_get_boolean(active) ||
            !json_object_object_get_ex(o, "rect", &rect)) continue;
        out.width = number(rect, "width");
        break;
    }
    return out;
}
