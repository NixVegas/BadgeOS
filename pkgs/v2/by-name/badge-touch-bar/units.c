#include "bar.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

bool unit_parse(struct unit_state *u, const char *text) {
    memset(u, 0, sizeof(*u));
    bool found = false;
    char *copy = strdup(text), *save = NULL;
    if (!copy) return false;
    for (char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (!strncmp(line, "ActiveState=", 12)) {
            const char *value = line + 12;
            u->active = strcmp(value, "inactive") && strcmp(value, "failed");
            u->ready = !strcmp(value, "active");
            u->stopping = !strcmp(value, "deactivating");
            u->failed |= !strcmp(value, "failed");
            found = true;
        } else if (!strncmp(line, "Result=", 7)) {
            u->failed |= line[7] && strcmp(line + 7, "success");
            snprintf(u->result, sizeof(u->result), "%s", line + 7);
        } else if (!strncmp(line, "Job=", 4)) {
            u->pending = strtoul(line + 4, NULL, 10) != 0;
        }
    }
    free(copy);
    u->active |= u->pending;
    u->ready &= !u->pending;
    return found;
}

static bool read_level(const char *dir, const char *name, int *value) {
    char path[640];
    if (snprintf(path, sizeof(path), "%s/%s", dir, name) >= (int)sizeof(path)) return false;
    FILE *f = fopen(path, "r");
    if (!f) return false;
    bool ok = fscanf(f, "%d", value) == 1;
    fclose(f);
    return ok;
}

bool brightness_step(const char *path, int change) {
    int level, max;
    if (!read_level(path, "brightness", &level) || !read_level(path, "max_brightness", &max) ||
        max < 1 || max > 65535 || level < 0 || level > max) return false;
    level += change;
    if (level < 1) level = 1;
    if (level > max) level = max;
    char file[640];
    if (snprintf(file, sizeof(file), "%s/brightness", path) >= (int)sizeof(file)) return false;
    FILE *f = fopen(file, "w");
    if (!f) return false;
    bool ok = fprintf(f, "%d\n", level) > 0;
    return fclose(f) == 0 && ok;
}

/* Helpers emit a state and one bounded display line; they run only on demand. */
bool setting_parse(struct setting_status *s, const char *text) {
    memset(s, 0, sizeof(*s));
    const char *line = strchr(text, '\n');
    if (!line) return false;
    size_t n = (size_t)(line - text);
    if (n == 2 && !strncmp(text, "on", n)) s->on = s->join = true;
    else if (n == 7 && !strncmp(text, "waiting", n)) s->on = true;
    else if (n != 3 || strncmp(text, "off", n)) return false;
    line++;
    n = strcspn(line, "\r\n");
    if (!n || n >= sizeof(s->label)) return false;
    memcpy(s->label, line, n);
    return true;
}
