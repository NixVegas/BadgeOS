#include "bar.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

bool process_start(struct process *p, char *const argv[]) {
    memset(p, 0, sizeof(*p));
    p->fd = -1;
    int fds[2];
    if (pipe2(fds, O_CLOEXEC)) return false;
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return false; }
    if (!pid) {
        dup2(fds[1], STDOUT_FILENO);
        int null = open("/dev/null", O_RDONLY);
        if (null >= 0) { dup2(null, STDIN_FILENO); close(null); }
        close(fds[0]); close(fds[1]);
        execvp(argv[0], argv);
        perror(argv[0]);
        _exit(127);
    }
    close(fds[1]);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    p->pid = pid;
    p->fd = fds[0];
    return true;
}

bool process_read(struct process *p) {
    if (p->fd < 0) return true;
    char buf[4096];
    for (;;) {
        ssize_t n = read(p->fd, buf, sizeof(buf));
        if (!n) { close(p->fd); p->fd = -1; return true; }
        if (n < 0) return errno == EAGAIN || errno == EINTR;
        if (p->len + (size_t)n + 1 > 262144) return false;
        if (p->len + (size_t)n + 1 > p->capacity) {
            size_t size = (p->len + (size_t)n + 4096) & ~(size_t)4095;
            char *data = realloc(p->data, size);
            if (!data) return false;
            p->data = data; p->capacity = size;
        }
        memcpy(p->data + p->len, buf, (size_t)n);
        p->len += (size_t)n;
        p->data[p->len] = 0;
    }
}

bool process_done(struct process *p) {
    if (!p->pid) return false;
    if (!p->exited && waitpid(p->pid, &p->status, WNOHANG) == p->pid) p->exited = true;
    return p->exited && p->fd < 0;
}

void process_clear(struct process *p) {
    if (p->pid && !p->exited) {
        /* These are IPC clients, never the managed app process. */
        kill(p->pid, SIGKILL);
        while (waitpid(p->pid, NULL, 0) < 0 && errno == EINTR) {}
    }
    if (p->fd >= 0) close(p->fd);
    free(p->data);
    memset(p, 0, sizeof(*p));
    p->fd = -1;
}
