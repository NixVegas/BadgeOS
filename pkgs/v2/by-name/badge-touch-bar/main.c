#include "bar.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

enum job_type { NONE, IMPORT, OUTPUTS, TREE, UNIT, LAUNCH, STOP_UNIT, SETTING_READ, SETTING_START, SETTING_STOP, KEYBOARD_START, KEYBOARD_TOGGLE, DISPLAY_MODE, BAR_SIZE, CORE_REBOOT };
struct runtime {
    struct config config;
    struct state state;
    struct process subscriber, job;
    enum job_type job_type;
    int job_app, start_app, stop_app, check_app, display_mode;
    struct output output;
    bool layout_pending;
    uint64_t unit_poll_at, job_deadline, reconnect_at, windows[MAX_APPS];
    struct unit_state units[MAX_APPS];
    unsigned unit_mask, setting_mask;
    int start_setting, stop_setting, keyboard_start, keyboard_toggle;
    bool subscribed, syncing, want_import, want_outputs, want_tree;
    enum core reboot_target;
};
static int signal_pipe[2];
static volatile sig_atomic_t stopping;
static void on_signal(int sig) {
    int saved = errno;
    if (sig != SIGCHLD) stopping = 1;
    char c = 0;
    (void)!write(signal_pipe[1], &c, 1);
    errno = saved;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void effects(struct runtime *r, unsigned effect) {
    if (effect & (FULL_SIZE | HALF_SIZE)) r->display_mode = effect & HALF_SIZE ? 2 : 1;
    if (effect & REBOOT_CORE) r->reboot_target = r->state.target_core;
    if (effect & TOGGLE_KEYBOARD) r->keyboard_start = r->state.app;
    if (effect & READ_SETTINGS) r->setting_mask = (1u << r->config.setting_count) - 1;
    if (effect & ENABLE_SETTING) r->start_setting = r->state.setting;
    if (effect & DISABLE_SETTING) r->stop_setting = r->state.setting;
    if (effect & START) r->start_app = r->state.app;
    if (effect & STOP) r->stop_app = r->state.app;
    if (effect & CHECK_UNIT) r->check_app = r->state.app;
    if (effect & (DIM | BRIGHT)) {
        if (!brightness_step(r->config.backlight, effect & DIM ? -1 : 1))
            state_step(&r->state, &r->config,
                       (struct event){.type=OP_FAILED, .error="Could not change brightness"}, now_ms());
    }
}

static void dispatch(struct runtime *r, struct event event) {
    effects(r, state_step(&r->state, &r->config, event, now_ms()));
}

static void disconnect_sway(struct runtime *r) {
    process_clear(&r->subscriber);
    /* A reboot service outlives its systemctl client and the display connection. */
    if (r->job_type != CORE_REBOOT) {
        process_clear(&r->job);
        r->job_type = NONE;
        r->job_deadline = 0;
    }
    if (r->reboot_target != CORE_UNKNOWN)
        dispatch(r, (struct event){.type=REBOOT_FAILED, .error="Display disconnected before reboot"});
    r->subscribed = false;
    r->syncing = true;
    r->want_import = r->want_outputs = r->want_tree = false;
    r->start_app = r->stop_app = r->check_app = -1;
    r->unit_poll_at = r->unit_mask = r->setting_mask = 0;
    r->start_setting = r->stop_setting = r->keyboard_start = r->keyboard_toggle = -1;
    r->display_mode = 0;
    r->layout_pending = false;
    r->reboot_target = CORE_UNKNOWN;
    r->state.keyboard_busy = false;
    r->state.setting_busy = r->state.display_busy = false;
    r->reconnect_at = now_ms() + 1000;
    r->state.revision++;
}

static void subscribe_sway(struct runtime *r) {
    char *args[] = {"swaymsg", "-r", "-m", "-t", "subscribe", "[\"window\",\"output\",\"tick\"]", NULL};
    if (process_start(&r->subscriber, args)) r->reconnect_at = 0;
    else r->reconnect_at = now_ms() + 1000;
}

static void subscription_event(struct runtime *r, json_object *event) {
    json_object *first;
    if (!r->subscribed) {
        /* swaymsg consumes the acknowledgement; the initial tick follows it. */
        if (!json_object_object_get_ex(event, "first", &first) ||
            !json_object_get_boolean(first)) { disconnect_sway(r); return; }
        r->subscribed = true;
        r->syncing = true;
        r->want_import = r->want_outputs = r->want_tree = true;
        r->setting_mask = (1u << r->config.setting_count) - 1;
        return;
    }
    if (json_object_object_get_ex(event, "first", &first)) return;
    json_object *container, *id;
    if (!json_object_object_get_ex(event, "container", &container)) {
        r->want_outputs = true;
        return;
    }
    const char *change = json_string(event, "change");
    if (strcmp(change, "new") && strcmp(change, "close")) return;
    if (!json_object_object_get_ex(container, "id", &id)) return;
    int app = app_find(&r->config, json_string(container, "app_id"));
    uint64_t con_id = json_object_get_uint64(id);
    if (!strcmp(change, "close")) {
        if (con_id == r->state.con_id) dispatch(r, (struct event){.type=WINDOW_CLOSED, .con_id=con_id});
        for (int i = 0; i < r->config.count; i++) if (r->windows[i] == con_id) r->windows[i] = 0;
    } else if (app >= 0) {
        if (!r->windows[app]) r->windows[app] = con_id;
        if (r->state.phase == APP && r->state.app == app)
            dispatch(r, (struct event){.type=WINDOW_NEW, .app=app, .con_id=con_id});
        else if (r->state.app != app) { r->syncing = true; r->want_tree = true; }
    }
    if (r->syncing) r->want_tree = true;
}

static bool consume_subscription(struct runtime *r) {
    struct process *p = &r->subscriber;
    if (!process_read(p)) return false;
    while (p->data) {
        char *newline = memchr(p->data, '\n', p->len);
        if (!newline) break;
        size_t used = (size_t)(newline - p->data) + 1;
        *newline = 0;
        json_object *event = json_tokener_parse(p->data);
        if (!event) return false;
        /* Consume first: a failed subscription may free its buffer. */
        memmove(p->data, p->data + used, p->len - used);
        p->len -= used;
        p->data[p->len] = 0;
        subscription_event(r, event);
        json_object_put(event);
        if (!p->pid) return true;
    }
    return !process_done(p);
}

static void start_job(struct runtime *r) {
    if (r->job.pid || !r->subscribed) return;
    char *args[20] = {0};
    char command[512];
    int app = -1;
    enum job_type type = NONE;
    if (r->display_mode) {
        type=DISPLAY_MODE;
        snprintf(command, sizeof(command), "output %s mode %dx%d", r->config.output,
                 r->output.full_width / r->display_mode, r->output.full_height / r->display_mode);
        args[0]="swaymsg"; args[1]="-q"; args[2]=command;
        r->display_mode=0;
    } else if (r->layout_pending) {
        type=BAR_SIZE;
        /* Height last: after a font change swaybar draws again only once its size changes. */
        snprintf(command, sizeof(command), "bar touch font pango:%s %d; bar touch height %d", r->config.font,
                 r->config.font_size / r->output.scale, r->config.bar_height / r->output.scale);
        args[0]="swaymsg"; args[1]="-q"; args[2]=command;
        r->layout_pending=false;
    }
    else if (r->reboot_target != CORE_UNKNOWN) {
        type=CORE_REBOOT;
        args[0]="systemctl"; args[1]="--no-ask-password"; args[2]="start"; args[3]="--";
        args[4]=r->reboot_target == CORE_ARM ? "badge-core-reboot@arm.service" : "badge-core-reboot@riscv.service";
        r->reboot_target=CORE_UNKNOWN;
    }
    else if (r->stop_app >= 0) { type=STOP_UNIT; app=r->stop_app; r->stop_app=-1; }
    else if (r->want_import) {
        type=IMPORT; r->want_import=false;
        char *import[] = {"systemctl", "--user", "import-environment", "WAYLAND_DISPLAY", "SWAYSOCK",
            "XDG_RUNTIME_DIR", "SDL_FRAMEBUFFER_ACCELERATION", "SDL_VIDEO_WAYLAND_SHM_FORMAT",
            "SDL_VIDEO_WAYLAND_MODE_SWITCH", NULL};
        memcpy(args, import, sizeof(import));
    } else if (r->start_app >= 0) { type=LAUNCH; app=r->start_app; r->start_app=-1; }
    else if (r->check_app >= 0) { type=UNIT; app=r->check_app; r->check_app=-1; }
    else if (r->want_outputs) {
        type=OUTPUTS; r->want_outputs=false;
        args[0]="swaymsg"; args[1]="-r"; args[2]="-t"; args[3]="get_outputs";
    } else if (r->want_tree) {
        type=TREE; r->want_tree=false;
        args[0]="swaymsg"; args[1]="-r"; args[2]="-t"; args[3]="get_tree";
    } else if (r->unit_mask) {
        type=UNIT;
        for (app=0; !(r->unit_mask & (1u << app)); app++) {}
        r->unit_mask &= ~(1u << app);
    } else if (r->stop_setting >= 0) {
        type=SETTING_STOP; app=r->stop_setting; r->stop_setting=-1;
    } else if (r->start_setting >= 0) {
        type=SETTING_START; app=r->start_setting; r->start_setting=-1;
    } else if (r->setting_mask) {
        type=SETTING_READ;
        for (app=0; !(r->setting_mask & (1u << app)); app++) {}
        r->setting_mask &= ~(1u << app);
    } else if (r->keyboard_start >= 0 || r->keyboard_toggle >= 0) {
        app = r->keyboard_start >= 0 ? r->keyboard_start : r->keyboard_toggle;
        type = r->keyboard_start >= 0 ? KEYBOARD_START : KEYBOARD_TOGGLE;
        r->keyboard_start = r->keyboard_toggle = -1;
        if (!state_app_ready(&r->state) || r->state.app != app) {
            dispatch(r, (struct event){.type=KEYBOARD_DONE, .app=app});
            return;
        }
    } else if (r->syncing) {
        state_restore(&r->state, &r->config, r->windows, r->units);
        r->syncing=false;
        if (r->state.app >= 0 && !r->state.window) r->unit_poll_at = now_ms() + 2000;
        r->state.revision++;
        return;
    }
    if (type == NONE) return;
    if (type == LAUNCH || type == STOP_UNIT || type == UNIT) {
        int n=0;
        args[n++]="systemctl";
        if (r->config.apps[app].system) args[n++]="--no-ask-password";
        else args[n++]="--user";
        args[n++]=type == UNIT ? "show" : type == LAUNCH ? "start" : "stop";
        if (type == UNIT) args[n++]="--property=ActiveState,Result,Job";
        else args[n++]="--no-block";
        args[n++]="--"; args[n++]=r->config.apps[app].unit;
    }
    if (type == SETTING_READ) {
        args[0]=r->config.settings[app].status_command;
    } else if (type == SETTING_STOP) {
        args[0]=r->config.settings[app].stop_command;
    } else if (type == SETTING_START) {
        args[0]="systemctl"; args[1]="--no-ask-password"; args[2]="restart";
        args[3]="--"; args[4]=r->config.settings[app].unit;
    }
    if (type == KEYBOARD_START || type == KEYBOARD_TOGGLE) {
        int n=0;
        args[n++]="systemctl"; args[n++]="--user";
        args[n++]=type == KEYBOARD_START ? "start" : "kill";
        if (type == KEYBOARD_TOGGLE) {
            args[n++]="--kill-whom=main"; args[n++]="--signal=SIGRTMIN";
        }
        args[n++]="--"; args[n++]=r->config.apps[app].keyboard_unit;
    }
    r->job_type=type; r->job_app=app;
    if (!process_start(&r->job, args)) {
        if (type == DISPLAY_MODE) dispatch(r, (struct event){.type=DISPLAY_DONE});
        if (type == UNIT && r->syncing) disconnect_sway(r);
        else if (type != UNIT) dispatch(r, (struct event){
            .type=type == CORE_REBOOT ? REBOOT_FAILED :
                  (type == KEYBOARD_START || type == KEYBOARD_TOGGLE) ? KEYBOARD_DONE :
                  (type == SETTING_START || type == SETTING_STOP || type == SETTING_READ) ? SETTING_FAILED : OP_FAILED,
            .app=app, .error="Could not start control command"});
        if (type == UNIT) r->unit_poll_at = now_ms() + 2000;
        r->job_type=NONE;
    } else if (!strcmp(args[0], "swaymsg")) {
        /* systemctl returns when systemd gives up on the job; Sway may not answer. */
        r->job_deadline = now_ms() + 30000;
    }
}

static void finish_job(struct runtime *r, bool timeout) {
    enum job_type type=r->job_type;
    int app=r->job_app;
    bool ok=!timeout && WIFEXITED(r->job.status) && WEXITSTATUS(r->job.status)==0;
    json_object *reply=NULL;
    if (ok && (type==OUTPUTS || type==TREE)) {
        reply=json_tokener_parse(r->job.data ? r->job.data : "");
        ok=reply != NULL;
    }
    if (ok && type==OUTPUTS) {
        struct output output=sway_output(reply, r->config.output);
        /* The sway config sizes the bar for Full. */
        if (output.width && output.scale != r->output.scale) r->layout_pending=true;
        r->output=output;
        r->state.half_mode=output.half;
        r->state.half_size=output.scale > 1;
        r->state.revision++;
    }
    else if (ok && type==TREE) {
        memset(r->windows, 0, sizeof(r->windows));
        sway_windows(reply, &r->config, r->windows);
        r->unit_mask=(1u << r->config.count)-1;
    } else if (ok && type==UNIT) {
        ok=unit_parse(&r->units[app], r->job.data ? r->job.data : "");
        if (ok && !r->syncing) dispatch(r, (struct event){.type=UNIT_CHANGED, .app=app, .unit=r->units[app]});
    } else if (ok && type==SETTING_READ) {
        struct setting_status status;
        ok=setting_parse(&status, r->job.data ? r->job.data : "");
        if (ok) dispatch(r, (struct event){.type=SETTING_CHANGED, .app=app, .setting_status=status});
    } else if (ok && (type==SETTING_START || type==SETTING_STOP)) {
        r->setting_mask |= 1u << app;
    } else if (type==LAUNCH || type==STOP_UNIT) {
        r->check_app=app;
    }
    if (type == UNIT && app == r->state.app &&
        (r->state.unit.active || r->state.window) && !state_app_ready(&r->state))
        r->unit_poll_at = now_ms() + 2000;
    if (reply) json_object_put(reply);
    process_clear(&r->job);
    r->job_type=NONE; r->job_deadline=0;
    if (type == DISPLAY_MODE) {
        dispatch(r, (struct event){.type=DISPLAY_DONE});
        r->want_outputs=true;
    }
    if (type == CORE_REBOOT) {
        if (!ok) dispatch(r, (struct event){.type=REBOOT_FAILED,
            .error=timeout ? "Reboot command timed out" : "Reboot refused; check system log"});
    } else if (type == KEYBOARD_START || type == KEYBOARD_TOGGLE) {
        if (ok && type == KEYBOARD_START) r->keyboard_toggle=app;
        else dispatch(r, (struct event){.type=KEYBOARD_DONE, .app=app,
            .error=ok ? NULL : timeout ? "Keyboard command timed out" : "Keyboard command failed"});
    } else if (!ok) {
        if (type==SETTING_READ || type==SETTING_START || type==SETTING_STOP) {
            dispatch(r, (struct event){.type=SETTING_FAILED, .app=app,
                .error=timeout ? "Setting command timed out" : "Setting command failed"});
        } else if (type==OUTPUTS || type==TREE || type==IMPORT || (type==UNIT && r->syncing)) {
            disconnect_sway(r);
        } else if (type!=UNIT) {
            dispatch(r, (struct event){.type=OP_FAILED, .error=timeout ? "Control command timed out" : "Control command failed"});
        }
    }
}

static bool read_clicks(struct runtime *r, char *line, size_t *length) {
    char buffer[4096];
    ssize_t n=read(STDIN_FILENO, buffer, sizeof(buffer));
    if (!n) return false;
    if (n<0) return errno==EAGAIN || errno==EINTR;
    for (ssize_t i=0; i<n; i++) {
        if (buffer[i]=='\n') {
            line[*length]=0;
            char *start=strchr(line, '{');
            if (start) {
                json_object *click=json_tokener_parse(start);
                struct event event;
                if (click && r->subscribed && !r->syncing && r->output.width>0 &&
                    bar_click(click, &r->state, &r->config, &event)) dispatch(r, event);
                if (click) json_object_put(click);
            }
            *length=0;
        } else {
            if (*length>=8191) return false;
            line[(*length)++]=buffer[i];
        }
    }
    return true;
}

static uint64_t earlier(uint64_t a, uint64_t b) { return !a || (b && b<a) ? b : a; }

int main(int argc, char **argv) {
    if (argc!=2) { fprintf(stderr, "usage: badge-touch-bar CONFIG.json\n"); return 2; }
    struct runtime r={.output.scale=1, .subscriber.fd=-1, .job.fd=-1, .start_app=-1, .stop_app=-1, .check_app=-1, .start_setting=-1, .stop_setting=-1, .keyboard_start=-1, .keyboard_toggle=-1, .syncing=true};
    if (!config_load(&r.config, argv[1])) return 2;
    state_init(&r.state);
    struct utsname machine;
    if (!uname(&machine)) r.state.current_core = !strcmp(machine.machine, "aarch64") ? CORE_ARM :
        !strcmp(machine.machine, "riscv64") ? CORE_RISCV : CORE_UNKNOWN;
    r.state.revision=(now_ms()<<16) ^ (unsigned)getpid();
    if (pipe2(signal_pipe, O_CLOEXEC|O_NONBLOCK)) return 1;
    struct sigaction sa={.sa_handler=on_signal, .sa_flags=SA_RESTART|SA_NOCLDSTOP};
    sigemptyset(&sa.sa_mask);
    sigaction(SIGCHLD, &sa, NULL); sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    int timer=timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC|TFD_NONBLOCK);
    if (timer<0) return 1;
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL)|O_NONBLOCK);
    puts("{\"version\":1,\"click_events\":true,\"stop_signal\":0}\n[");
    subscribe_sway(&r);
    char click_line[8192]; size_t click_length=0;
    uint64_t rendered=0;
    while (!stopping && !ferror(stdout)) {
        uint64_t now=now_ms();
        if (r.reconnect_at && now>=r.reconnect_at) subscribe_sway(&r);
        dispatch(&r, (struct event){.type=TICK});
        if (r.job.pid) {
            bool read_ok=process_read(&r.job);
            if (!read_ok || (r.job_deadline && now>=r.job_deadline)) finish_job(&r, true);
            else if (process_done(&r.job)) finish_job(&r, false);
        }
        if (r.unit_poll_at && now_ms() >= r.unit_poll_at) {
            r.unit_poll_at = 0;
            if (r.state.app >= 0) r.check_app = r.state.app;
        }
        start_job(&r);
        if (rendered!=r.state.revision) {
            bar_render(&r.state, &r.config, r.output.width, r.subscribed && !r.syncing && r.output.width>0);
            rendered=r.state.revision;
        }
        uint64_t next=earlier(r.state.deadline, earlier(r.unit_poll_at, earlier(r.job_deadline,r.reconnect_at)));
        struct itimerspec deadline={0};
        if (next) { deadline.it_value.tv_sec=(time_t)(next/1000); deadline.it_value.tv_nsec=(long)(next%1000)*1000000; }
        timerfd_settime(timer, TFD_TIMER_ABSTIME, &deadline, NULL);
        struct pollfd fds[]={{STDIN_FILENO,POLLIN,0},{r.subscriber.fd,POLLIN,0},
            {r.job.fd,POLLIN,0},{timer,POLLIN,0},{signal_pipe[0],POLLIN,0}};
        if (poll(fds,5,-1)<0 && errno!=EINTR) break;
        if (fds[0].revents && !read_clicks(&r,click_line,&click_length)) break;
        if (fds[1].revents && !consume_subscription(&r)) disconnect_sway(&r);
        if (fds[3].revents) { uint64_t ticks; (void)!read(timer,&ticks,sizeof(ticks)); }
        if (fds[4].revents) {
            char signals[64]; while (read(signal_pipe[0],signals,sizeof(signals))>0) {}
            if (r.subscriber.pid && !consume_subscription(&r)) disconnect_sway(&r);
        }
    }
    process_clear(&r.job); process_clear(&r.subscriber);
    close(timer); close(signal_pipe[0]); close(signal_pipe[1]);
    return 0;
}
