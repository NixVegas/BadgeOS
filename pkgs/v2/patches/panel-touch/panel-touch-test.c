#include "panel_touch.h"
#include <assert.h>
#include <stdio.h>

static void fill(void *context, int x, int y, int w, int h, unsigned shade)
{
    (void)x; (void)y;
    assert(w > 0 && h > 0 && shade <= 255);
    (*(int *)context)++;
}
static void neutral(struct pt_output o)
{
    assert(o.strafe == 0 && o.forward == 0 && o.held == 0);
}
int main(void)
{
    struct panel_touch p = {0};
    pt_resize(&p, 552, 320);
    pt_event(&p, PT_DOWN, 1, .2f, .7f);
    pt_event(&p, PT_MOTION, 1, .205f, .7f);
    neutral(pt_take(&p)); /* Dead zone. */
    pt_event(&p, PT_MOTION, 1, .25f, .6f);
    struct pt_output o = pt_take(&p);
    assert(o.strafe > 0 && o.strafe < 1 && o.forward > 0 && o.forward < 1);
    pt_event(&p, PT_MOTION, 1, .9f, .1f); /* Ownership outside the stick region. */
    o=pt_take(&p);
    assert(fabsf(o.strafe*o.strafe + o.forward*o.forward - 1) < .0001f);

    pt_event(&p, PT_DOWN, 2, .9f, .9f);
    o=pt_take(&p);
    assert(o.pressed == (1u << PT_FIRE) && o.strafe > 0 && o.forward > 0);
    pt_event(&p, PT_MOTION, 2, .5f, .5f); /* FIRE keeps aiming outside its box. */
    o=pt_take(&p);
    assert(o.held == (1u << PT_FIRE) && o.pressed == 0 && o.look_x < 0 && o.look_y < 0);
    pt_event(&p, PT_DOWN, 3, .9f, .9f);
    assert(pt_take(&p).pressed == 0); /* Two fingers share a held button. */
    pt_event(&p, PT_UP, 2, .5f, .5f);
    assert(pt_take(&p).released == 0);
    pt_event(&p, PT_UP, 3, .9f, .9f);
    assert(pt_take(&p).released == (1u << PT_FIRE));
    pt_event(&p, PT_UP, 1, .9f, .1f);
    neutral(pt_take(&p));

    pt_event(&p, PT_DOWN, 1, .9f, .1f); /* Reused finger ID owns OK now. */
    assert(pt_take(&p).pressed == (1u << PT_OK));
    pt_event(&p, PT_DOWN, 1, .9f, .1f); /* Duplicate down produces no extra edge. */
    assert(pt_take(&p).pressed == 0);
    pt_event(&p, PT_DOWN, 4, .6f, .4f);
    pt_event(&p, PT_MOTION, 4, .7f, .5f);
    o=pt_take(&p);
    assert(o.look_x > 55 && o.look_x < 56 && o.look_y > 31 && o.look_y < 33);
    assert(pt_take(&p).look_x == 0);
    pt_release_all(&p); /* Focus loss releases everything, including button edges. */
    o=pt_take(&p); neutral(o);
    assert(o.released == (1u << PT_OK) && o.look_x == 0 && o.look_y == 0);
    pt_event(&p, PT_MOTION, 1, .5f, .5f);
    neutral(pt_take(&p)); /* Late events after focus loss cannot revive a finger. */

    pt_event(&p, PT_DOWN, 5, .65f, .1f);
    pt_event(&p, PT_UP, 5, .65f, .1f);
    o=pt_take(&p);
    assert(o.pressed == (1u << PT_GUN) && o.released == o.pressed && !o.held);
    pt_event(&p, PT_DOWN, 6, .2f, .7f);
    pt_event(&p, PT_DOWN, 7, .3f, .8f);
    pt_event(&p, PT_MOTION, 6, .2f, .5f);
    pt_event(&p, PT_MOTION, 7, .4f, .9f);
    o=pt_take(&p);
    assert(o.forward > 0 && o.strafe == 0); /* Only one stick owner. */
    pt_resize(&p, 320, 200);
    neutral(pt_take(&p));
    int calls = 0;
    pt_draw(&p, fill, &calls, "JUMP");
    assert(calls > 50);
    puts("stick ownership, analog range, edges, simultaneous fire/look and release passed");
}
