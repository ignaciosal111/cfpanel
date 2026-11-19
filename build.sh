#!/usr/bin/env bash
set -euo pipefail
BASE="$1"; OUT=out; rm -rf work "$OUT"; mkdir -p "$OUT" javasrc/com/cfpanel modmenu/jni build

cat > javasrc/com/cfpanel/Panel.java <<'EOF'
package com.cfpanel;
import android.app.Activity; import android.content.Context; import android.graphics.Color;
import android.graphics.PixelFormat; import android.view.Gravity; import android.view.MotionEvent;
import android.view.Surface; import android.view.SurfaceHolder; import android.view.SurfaceView;
import android.view.WindowManager; import android.widget.TextView;
public final class Panel {
  static { System.loadLibrary("modmenu"); }
  private static Activity act; private static WindowManager wm; private static SurfaceView sv;
  private static TextView handle; private static boolean moved; private static int dx, dy;
  public static void init(Activity a) { act = a; a.runOnUiThread(() -> { try { mount(); } catch (Throwable t) { t.printStackTrace(); } }); }
  private static void mount() {
    wm = (WindowManager) act.getSystemService(Context.WINDOW_SERVICE);
    final int T = WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY;
    sv = new SurfaceView(act); sv.setZOrderMediaOverlay(true);
    sv.getHolder().setFormat(PixelFormat.TRANSLUCENT);
    sv.getHolder().addCallback(new SurfaceHolder.Callback() {
      public void surfaceCreated(SurfaceHolder h) { onSurface(h.getSurface(), sv.getWidth(), sv.getHeight()); }
      public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) { onSurface(h.getSurface(), w, hh); }
      public void surfaceDestroyed(SurfaceHolder h) { onSurfaceDestroyed(); } });
    sv.setOnTouchListener((v, e) -> { nativeTouch(e.getActionMasked(), e.getX(), e.getY()); return true; });
    WindowManager.LayoutParams slp = new WindowManager.LayoutParams(-1, -1, T,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSLUCENT);
    slp.gravity = Gravity.TOP | Gravity.START; wm.addView(sv, slp);
    handle = new TextView(act); handle.setText(" CF "); handle.setTextColor(Color.WHITE);
    handle.setTextSize(13); handle.setBackgroundColor(0xCC101014);
    handle.setOnTouchListener((v, e) -> {
      switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN: moved = false; dx = (int) e.getRawX(); dy = (int) e.getRawY(); return true;
        case MotionEvent.ACTION_MOVE:
          if (Math.abs(e.getRawX() - dx) > 12 || Math.abs(e.getRawY() - dy) > 12) {
            moved = true;
            WindowManager.LayoutParams hlp = (WindowManager.LayoutParams) handle.getLayoutParams();
            hlp.x = (int) e.getRawX() - handle.getWidth() / 2; hlp.y = (int) e.getRawY() - handle.getHeight() / 2;
            wm.updateViewLayout(handle, hlp); }
          return true;
        case MotionEvent.ACTION_UP: if (!moved) toggle(); return true; }
      return false; });
    WindowManager.LayoutParams hlp = new WindowManager.LayoutParams(-2, -2, T,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT);
    hlp.gravity = Gravity.TOP | Gravity.START; hlp.x = 20; hlp.y = 320; wm.addView(handle, hlp);
  }
  private static void toggle() {
    boolean open = !isMenuOpen(); setMenuOpen(open);
    WindowManager.LayoutParams slp = (WindowManager.LayoutParams) sv.getLayoutParams();
    if (open) slp.flags &= ~WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
    else slp.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
    wm.updateViewLayout(sv, slp);
  }
  public static native boolean isMenuOpen();
  public static native void setMenuOpen(boolean open);
  public static native void nativeTouch(int action, float x, float y);
  public static native void onSurface(Surface s, int w, int h);
  public static native void onSurfaceDestroyed();
}
EOF

cat > modmenu/jni/Application.mk <<'EOF'
APP_ABI := arm64-v8a
APP_PLATFORM := android-26
APP_STL := c++_static
APP_CPPFLAGS := -std=c++17 -fexceptions -frtti -O2
EOF

cat > modmenu/jni/Android.mk <<'EOF'
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := modmenu
LOCAL_SRC_FILES := modmenu.cpp imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp imgui_impl_opengl3.cpp imgui_impl_android.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)
LOCAL_LDLIBS := -llog -landroid -lEGL -lGLESv3 -ldl
include $(BUILD_SHARED_LIBRARY)
EOF

cat > modmenu/jni/modmenu.cpp <<'EOF'
#include <jni.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <math.h>
#include "imgui.h"
#include "imgui_impl_android.h"
#include "imgui_impl_opengl3.h"
#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "CFPanel", __VA_ARGS__)
#define NS_PLAYER ""
#define CLS_PLAYER "PlayerController"
#define FLD_HEAD "headTransform"
#define FLD_TEAM "team"
#define FLD_HEALTH "health"
#define FLD_LOCAL "isLocalPlayer"
struct Vec3 { float x, y, z; };
struct Quat { float x, y, z, w; };
static ANativeWindow* g_win; static int g_w = 1, g_h = 1;
static bool g_menu, g_esp = true, g_aim, g_headOnly = true;
static float g_fov = 220.f, g_smooth = 5.f;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static float g_tx, g_ty; static int g_ta = -1;
static void* (*p_dom)(); static void* (*p_asms)(void*, size_t*); static void* (*p_img)(void*);
static void* (*p_cfn)(void*, const char*, const char*); static void* (*p_meth)(void*, const char*, int);
static void* (*p_fld)(void*, const char*); static size_t (*p_off)(void*);
static void* (*p_inv)(void*, void*, void**, void**); static void* (*p_ctype)(void*);
static uint32_t (*p_arrlen)(void*);
static void* KPLAYER, *KCAM, *KOBJ, *KTRANS; static void* mGetMain, *mW2C, *mProj, *mFind, *mGetTr, *mGetPos, *mGetRot, *mSetRot;
static size_t offHead, offHealth, offLocal;
static void* Sym(const char* n) { return dlsym(RTLD_DEFAULT, n); }
static void* Class(const char* ns, const char* n) {
  size_t c = 0; void** a = (void**)p_asms(p_dom(), &c);
  for (size_t i = 0; i < c; i++) { void* im = p_img(a[i]); if (!im) continue; void* k = p_cfn(im, ns, n); if (k) return k; }
  return nullptr; }
static void* M(void* k, const char* n, int ac) { if (!k) return nullptr; void* m = p_meth(k, n, ac); return m ? *(void**)m : nullptr; }
static size_t F(void* k, const char* n) { if (!k) return 0; void* f = p_fld(k, n); return f ? p_off(f) : 0; }
static void* Inv(void* m, void* o, void** a) { if (!m) return nullptr; void* e = nullptr; void* r = p_inv(m, o, a, &e); return e ? nullptr : r; }
static Vec3 Pos(void* tr) { void* r = Inv(mGetPos, tr, nullptr); return r ? *(Vec3*)((char*)r + 0x10) : Vec3{}; }
static Quat Rot(void* tr) { void* r = Inv(mGetRot, tr, nullptr); return r ? *(Quat*)((char*)r + 0x10) : Quat{0,0,0,1}; }
static bool Res() {
  if (!Sym("il2cpp_domain_get")) return false;
  p_dom = (void*(*)())Sym("il2cpp_domain_get"); p_asms = (void*(*)(void*,size_t*))Sym("il2cpp_domain_get_assemblies");
  p_img = (void*(*)(void*))Sym("il2cpp_assembly_get_image");
  p_cfn = (void*(*)(void*,const char*,const char*))Sym("il2cpp_class_from_name");
  p_meth = (void*(*)(void*,const char*,int))Sym("il2cpp_class_get_method_from_name");
  p_fld = (void*(*)(void*,const char*))Sym("il2cpp_class_get_field_from_name");
  p_off = (size_t(*)(void*))Sym("il2cpp_field_get_offset");
  p_inv = (void*(*)(void*,void*,void**,void**))Sym("il2cpp_runtime_invoke");
  p_ctype = (void*(*)(void*))Sym("il2cpp_class_get_type");
  p_arrlen = (uint32_t(*)(void*))Sym("il2cpp_array_length");
  KPLAYER = Class(NS_PLAYER, CLS_PLAYER); KCAM = Class("UnityEngine", "Camera");
  KOBJ = Class("UnityEngine", "Object"); KTRANS = Class("UnityEngine", "Transform");
  if (!KPLAYER || !KCAM || !KTRANS) { LOG("FALLO clases (revisa CLS_PLAYER)"); return false; }
  offHead = F(KPLAYER, FLD_HEAD); offHealth = F(KPLAYER, FLD_HEALTH); offLocal = F(KPLAYER, FLD_LOCAL);
  mGetMain = M(KCAM, "get_main", 0); mW2C = M(KCAM, "get_worldToCameraMatrix", 0); mProj = M(KCAM, "get_projectionMatrix", 0);
  mFind = M(KOBJ, "FindObjectsOfType", 1);
  mGetTr = M(KPLAYER, "get_transform", 0); if (!mGetTr) mGetTr = M(KCAM, "get_transform", 0);
  mGetPos = M(KTRANS, "get_position", 0); mGetRot = M(KTRANS, "get_rotation", 0); mSetRot = M(KTRANS, "set_rotation", 1);
  LOG("offs hp=%zx local=%zx head=%zx", offHealth, offLocal, offHead);
  return offHead && mGetMain && mFind && mSetRot; }
static bool W2S(const float* m, Vec3 p, float sw, float sh, ImVec2& o) {
  float x = m[0]*p.x + m[4]*p.y + m[8]*p.z + m[12], y = m[1]*p.x + m[5]*p.y + m[9]*p.z + m[13], w = m[3]*p.x + m[7]*p.y + m[11]*p.z + m[15];
  if (w < 0.001f) return false; o.x = sw * .5f * (1 + x / w); o.y = sh * .5f * (1 - y / w); return true; }
static Quat Look(Vec3 d) {
  float yaw = atan2f(d.x, d.z) * 57.29578f, pit = -atan2f(d.y, sqrtf(d.x*d.x + d.z*d.z)) * 57.29578f;
  float a = yaw * .0087266f, b = pit * .0087266f;
  return { cosf(a)*cosf(b), sinf(a)*cosf(b), -sinf(a)*sinf(b), cosf(a)*sinf(b) }; }
static Quat Sl(Quat a, Quat b, float t) {
  float d = a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w; if (d < 0) { b = {-b.x,-b.y,-b.z,-b.w}; d = -d; }
  if (d > .9995f) return b; float th = acosf(d), s = sinf(th), s1 = sinf((1-t)*th)/s, s2 = sinf(t*th)/s;
  return { a.x*s1+b.x*s2, a.y*s1+b.y*s2, a.z*s1+b.z*s2, a.w*s1+b.w*s2 }; }
static EGLDisplay g_d; static EGLSurface g_s; static EGLContext g_c; static bool g_ok;
static bool EInit(ANativeWindow* w) {
  g_d = eglGetDisplay(EGL_DEFAULT_DISPLAY); eglInitialize(g_d, nullptr, nullptr);
  const EGLint ca[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE };
  EGLConfig cfg; EGLint n = 0; eglChooseConfig(g_d, ca, &cfg, 1, &n);
  const EGLint xa[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
  g_c = eglCreateContext(g_d, cfg, EGL_NO_CONTEXT, xa); g_s = eglCreateWindowSurface(g_d, cfg, w, nullptr);
  g_ok = eglMakeCurrent(g_d, g_s, g_s, g_c); return g_ok; }
static void EStop() {
  g_ok = false; if (g_d) { eglMakeCurrent(g_d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (g_s) eglDestroySurface(g_d, g_s); if (g_c) eglDestroyContext(g_d, g_c); eglTerminate(g_d); }
  g_d = EGL_NO_DISPLAY; g_s = EGL_NO_SURFACE; g_c = EGL_NO_CONTEXT; }
static void* Loop(void*) {
  while (!g_win) usleep(100000);
  if (!EInit(g_win)) { LOG("EGL fallo"); return nullptr; }
  IMGUI_CHECKVERSION(); ImGui::CreateContext(); ImGui::GetIO().IniFilename = nullptr; ImGui::StyleColorsDark();
  ImGui_ImplOpenGL3_Init("#version 300 es"); ImGui_ImplAndroid_Init(g_win);
  while (g_ok) {
    ANativeWindow_acquire(g_win);
    ImGuiIO& io = ImGui::GetIO(); io.DisplaySize = ImVec2((float)g_w, (float)g_h);
    pthread_mutex_lock(&g_lock);
    if (g_ta >= 0) { io.AddMousePosEvent(g_tx, g_ty); if (g_ta == 0) io.AddMouseButtonEvent(0, true); if (g_ta == 1 || g_ta == 3) io.AddMouseButtonEvent(0, false); g_ta = -1; }
    pthread_mutex_unlock(&g_lock);
    ImGui_ImplOpenGL3_NewFrame(); ImGui_ImplAndroid_NewFrame(); ImGui::NewFrame();
    void* cam = Inv(mGetMain, nullptr, nullptr); float vp[16] = {0};
    if (cam) { void* a = Inv(mW2C, cam, nullptr); void* b = Inv(mProj, cam, nullptr);
      if (a && b) { float* A = (float*)((char*)a + 16); float* B = (float*)((char*)b + 16);
        for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) { float s = 0;
          for (int k = 0; k < 4; k++) s += A[k*4+r] * B[c*4+k]; vp[c*4+r] = s; } } }
    void* ents[64]; int n = 0;
    if (KPLAYER) { void* ty = p_ctype(KPLAYER); void* ar[1] = { ty };
      void* arr = Inv(mFind, nullptr, ar);
      if (arr) { uint32_t len = p_arrlen(arr); void** v = (void**)((char*)arr + 32);
        for (uint32_t i = 0; i < len && n < 64; i++) if (v[i]) ents[n++] = v[i]; } }
    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    Vec3 best{}; bool has = false; float bd = 1e9f; ImVec2 ct(g_w * .5f, g_h * .5f);
    for (int i = 0; i < n; i++) {
      char* o = (char*)ents[i];
      if (offLocal && *(bool*)(o + offLocal)) continue;
      if (offHealth && *(int*)(o + offHealth) <= 0) continue;
      void* tr = Inv(mGetTr, ents[i], nullptr); if (!tr) continue;
      Vec3 pos = Pos(tr); ImVec2 s; if (!W2S(vp, pos, (float)g_w, (float)g_h, s)) continue;
      if (g_esp) { float h = 12000.f / (s.y + 1.f);
        dl->AddRect(ImVec2(s.x - h*.22f, s.y - h), ImVec2(s.x + h*.22f, s.y), IM_COL32(255,80,80,220), 0, 0, 1.6f);
        dl->AddLine(ImVec2(ct.x, (float)g_h), s, IM_COL32(255,255,255,90), 1.f); }
      float sc = sqrtf((s.x-ct.x)*(s.x-ct.x) + (s.y-ct.y)*(s.y-ct.y));
      if (g_aim && sc < g_fov && sc < bd) { bd = sc; best = pos; has = true; } }
    if (g_aim && has && cam) { void* tr = Inv(mGetTr, cam, nullptr);
      if (tr) { Vec3 or_ = Pos(tr); Vec3 d { best.x - or_.x, best.y + (g_headOnly ? 1.6f : 1.1f) - or_.y, best.z - or_.z };
        Quat w = Look(d), c = Rot(tr); Quat r = Sl(c, w, 1.f / g_smooth); void* ar[1] = { &r }; Inv(mSetRot, tr, ar); } }
    if (g_aim) dl->AddCircle(ct, g_fov, IM_COL32(120,200,255,140), 64, 1.5f);
    if (g_menu) { ImGui::SetNextWindowSize(ImVec2(330, 400), ImGuiCond_FirstUseEver); ImGui::Begin("CF Panel");
      ImGui::Checkbox("ESP", &g_esp); ImGui::Checkbox("Aimbot", &g_aim); ImGui::Checkbox("Solo cabeza", &g_headOnly);
      ImGui::SliderFloat("FOV", &g_fov, 20.f, 600.f); ImGui::SliderFloat("Suavizado", &g_smooth, 1.f, 20.f);
      ImGui::Separator(); ImGui::Text("entidades: %d", n); ImGui::End(); }
    ImGui::Render(); glViewport(0, 0, g_w, g_h); glClearColor(0,0,0,0); glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData()); eglSwapBuffers(g_d, g_s);
    ANativeWindow_release(g_win); usleep(16000); }
  ImGui_ImplOpenGL3_Shutdown(); ImGui_ImplAndroid_Shutdown(); ImGui::DestroyContext(); EStop(); return nullptr; }
static void* Boot(void*) {
  for (int i = 0; i < 300; i++) { if (dlopen("libil2cpp.so", RTLD_NOW) && Res()) break; usleep(200000); }
  return nullptr; }
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM*, void*) { pthread_t t; pthread_create(&t, nullptr, Boot, nullptr); return JNI_VERSION_1_6; }
extern "C" JNIEXPORT jboolean JNICALL Java_com_cfpanel_Panel_isMenuOpen(JNIEnv*, jclass) { return g_menu; }
extern "C" JNIEXPORT void JNICALL Java_com_cfpanel_Panel_setMenuOpen(JNIEnv*, jclass, jboolean v) { g_menu = v; }
extern "C" JNIEXPORT void JNICALL Java_com_cfpanel_Panel_nativeTouch(JNIEnv*, jclass, jint a, jfloat x, jfloat y) {
  pthread_mutex_lock(&g_lock); g_tx = x; g_ty = y; g_ta = (a == 0) ? 0 : (a == 1) ? 1 : (a == 3) ? 3 : -1; pthread_mutex_unlock(&g_lock); }
extern "C" JNIEXPORT void JNICALL Java_com_cfpanel_Panel_onSurface(JNIEnv* env, jclass, jobject s, jint w, jint h) {
  if (s) { g_win = ANativeWindow_fromSurface(env, s); g_w = w; g_h = h; }
  static bool st = false; if (!st) { st = true; pthread_t t; pthread_create(&t, nullptr, Loop, nullptr); } }
extern "C" JNIEXPORT void JNICALL Java_com_cfpanel_Panel_onSurfaceDestroyed(JNIEnv*, jclass) {
  EStop(); if (g_win) { ANativeWindow_release(g_win); g_win = nullptr; } }
EOF

cat > patch_smali.py <<'EOF'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1]); mf = (root / "AndroidManifest.xml").read_text(errors="ignore")
act = re.search(r'<activity[^>]*android:name="([\w.$]+)"', mf)
if not act: sys.exit("sin activity")
f = root / "smali" / (act.group(1).replace('.', '/') + ".smali"); txt = f.read_text()
m = re.search(r'\.method (?:public|protected) onCreate\(Landroid/os/Bundle;\)V\n(    \.locals \d+\n)', txt)
if not m: sys.exit("sin onCreate")
ins = m.group(1) + '\n    invoke-static {p0}, Lcom/cfpanel/Panel;->init(Landroid/app/Activity;)V\n'
f.write_text(txt[:m.start(1)] + ins + txt[m.end(1):]); print("ok", act.group(1))
EOF

BT=$ANDROID_HOME/build-tools/34.0.0
javac -source 8 -target 8 -nowarn -cp "$ANDROID_HOME/platforms/android-34/android.jar" -d build javasrc/com/cfpanel/Panel.java
$BT/d8 --lib "$ANDROID_HOME/platforms/android-34/android.jar" --output build build/com/cfpanel/Panel.class

curl -sL https://github.com/ocornut/imgui/archive/refs/tags/v1.90.9.tar.gz | tar xz
cp imgui-1.90.9/imgui.cpp imgui-1.90.9/imgui_draw.cpp imgui-1.90.9/imgui_tables.cpp imgui-1.90.9/imgui_widgets.cpp imgui-1.90.9/imgui.h imgui-1.90.9/imgui_internal.h imgui-1.90.9/imstb_*.h imgui-1.90.9/imconfig.h modmenu/jni/
cp imgui-1.90.9/backends/imgui_impl_opengl3.* imgui-1.90.9/backends/imgui_impl_opengl3_loader.h imgui-1.90.9/backends/imgui_impl_android.* modmenu/jni/

apktool d -f -o work "$BASE"
pushd modmenu/jni >/dev/null && "$NDK/ndk-build" NDK_PROJECT_PATH=.. -j8 && popd >/dev/null
mkdir -p work/lib/arm64-v8a && cp modmenu/libs/arm64-v8a/libmodmenu.so work/lib/arm64-v8a/
python3 patch_smali.py work
apktool b work -o "$OUT/u.apk"

mv build/classes.dex build/classes2.dex
pushd build >/dev/null && zip -q "$OLDPWD/$OUT/u.apk" classes2.dex && popd >/dev/null

zipalign -p -f 4 "$OUT/u.apk" "$OUT/a.apk"
keytool -genkeypair -keystore "$OUT/k.jks" -alias m -keyalg RSA -keysize 2048 -validity 9999 -storepass modpass -keypass modpass -dname "CN=m" 2>/dev/null
apksigner sign --ks "$OUT/k.jks" --ks-pass pass:modpass --key-pass pass:modpass --out "$OUT/CounterFlame-Panel.apk" "$OUT/a.apk"
echo "LISTO"
