// Renders a puppet with the original Inochi2D 0.8 OpenGL renderer into raw
// premultiplied RGBA. Runs headless on Mesa (EGL surfaceless); bindbc only
// tries EGL when XDG_SESSION_TYPE=wayland, so run.sh sets that.
// Usage: inochi2d-glreference model out.rgba width height centreX centreY scale
import inochi2d;
import bindbc.opengl;
import std.exception;
import std.stdio, std.conv, std.string, std.algorithm, std.array, std.format, std.file;

extern(C) nothrow @nogc {
    alias EGLDisplay = void*; alias EGLConfig = void*; alias EGLContext = void*; alias EGLSurface = void*;
    EGLDisplay eglGetPlatformDisplay(uint platform, void* native, const(long)* attribs);
    uint eglInitialize(EGLDisplay, int*, int*);
    uint eglBindAPI(uint);
    uint eglChooseConfig(EGLDisplay, const(int)*, EGLConfig*, int, int*);
    EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const(int)*);
    uint eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
    int eglGetError();
}

__gshared double now_ = 0;
double timeFunc() { return now_; }

void main(string[] args) {
    enum EGL_PLATFORM_SURFACELESS_MESA = 0x31DD, EGL_OPENGL_API = 0x30A2, EGL_NONE = 0x3038;
    auto dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, null, null);
    int maj, min; enforce(eglInitialize(dpy, &maj, &min), "eglInitialize");
    eglBindAPI(EGL_OPENGL_API);
    int[] cfgAttr = [0x3040 /*RENDERABLE_TYPE*/, 0x0008 /*OPENGL_BIT*/, 0x3033 /*SURFACE_TYPE*/, 0, EGL_NONE];
    EGLConfig cfg; int n;
    enforce(eglChooseConfig(dpy, cfgAttr.ptr, &cfg, 1, &n) && n > 0, "config");
    int[] ctxAttr = [0x3098, 3, 0x30FB, 3, 0x30FD /*PROFILE_MASK*/, 1, EGL_NONE];
    auto ctx = eglCreateContext(dpy, cfg, null, ctxAttr.ptr);
    enforce(ctx !is null, "context " ~ eglGetError().to!string);
    enforce(eglMakeCurrent(dpy, null, null, ctx), "makecurrent");
    auto support = loadOpenGL();
    stderr.writeln("GL loaded: ", support, " ctx ", loadedOpenGLVersion, " advanced blend: ", hasKHRBlendEquationAdvanced);

    inInit(&timeFunc);
    int W = args[3].to!int, H = args[4].to!int;
    inSetViewport(W, H);
    inSetClearColor(0, 0, 0, 0);
    Puppet p = inLoadPuppet(args[1]);
    p.enableDrivers = false;
    // Camera: model centre -> viewport centre, given scale.
    auto cam = inGetCamera();
    float cx = args[5].to!float, cy = args[6].to!float, sc = args[7].to!float;
    cam.position = vec2(-cx, -cy);
    cam.scale = vec2(sc, sc);
    inSetCamera(cam);
    now_ += 1.0/60; inUpdate();
    p.update();
    inBeginScene();
    p.draw();
    inEndScene();
    ubyte[] buf = new ubyte[inViewportDataLength()];
    inDumpViewport(buf);
    std.file.write(args[2], buf);
}
