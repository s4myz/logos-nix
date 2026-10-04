/*
 * nowineshape: LD_PRELOAD shim for Wine under wlroots-style compositors
 * (Hyprland, Sway, ...).
 *
 * Since Wine 9.12 (commit 0931c2a4) every per-pixel-alpha layered window, i.e.
 * every Logos tooltip, menu and popup with a drop shadow, gets an XShape
 * bounding mask derived from its alpha channel. wlroots compositors don't
 * apply XShape to XWayland surfaces, and XWayland leaves the pixels outside
 * the shape stale, so the transparent shadow margin is drawn as an opaque
 * box around the popup. Mutter and KWin apply the shape, so GNOME and KDE
 * are unaffected.
 *
 * Under a compositor the mask is pointless (it only lets non-compositing X
 * setups click through transparent pixels), so drop exactly that call:
 * XShapeCombineMask() on ShapeBounding with a real mask pixmap. Shape resets
 * and XShapeCombineRectangles/Region (SetWindowRgn, hiding zero-sized
 * windows) pass through.
 *
 * Diagnosis and the original shim: FaithLife-Community/OuDedetai PR #497.
 */
#define _GNU_SOURCE
#include <dlfcn.h>

#define ShapeBounding 0
#define None 0L

typedef void Display;
typedef unsigned long Window;
typedef unsigned long Pixmap;

void XShapeCombineMask(Display *dpy, Window dest, int dest_kind, int x_off,
                       int y_off, Pixmap src, int op)
{
    static void (*real)(Display *, Window, int, int, int, Pixmap, int);

    if (dest_kind == ShapeBounding && src != None)
        return;

    if (!real)
        real = dlsym(RTLD_NEXT, "XShapeCombineMask");
    if (real)
        real(dpy, dest, dest_kind, x_off, y_off, src, op);
}
