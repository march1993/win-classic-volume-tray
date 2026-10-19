//! Windows Classic Volume Tray (Zig rewrite)
//!
//! A tiny tray application that shows a classic vertical volume slider when the
//! tray icon is clicked. Only Win32 / COM APIs are used, no third-party code.
//!
//! Notable fixes compared to the Go version:
//!   * The audio endpoint is acquired lazily and retried (via a timer) instead of
//!     exiting when the audio service is not ready yet at logon.
//!   * The default audio endpoint is refreshed whenever the popup is opened and
//!     whenever a COM call fails, so volume changes always reach the device that
//!     is actually rendering audio.
//!   * The tray icon is re-added when Explorer restarts ("TaskbarCreated").

const std = @import("std");

// ---------------------------------------------------------------------------
// Win32 base types
// ---------------------------------------------------------------------------

const BOOL = i32;
const HRESULT = i32;
const HWND = *opaque {};
const HINSTANCE = *opaque {};
const HICON = *opaque {};
const HCURSOR = *opaque {};
const HBRUSH = *opaque {};
const HMENU = *opaque {};
const HMONITOR = *opaque {};
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const ATOM = u16;

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const POINT = extern struct {
    x: i32,
    y: i32,
};

const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: ?WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

const NOTIFYICONDATAW = extern struct {
    cbSize: u32,
    hWnd: ?HWND,
    uID: u32,
    uFlags: u32,
    uCallbackMessage: u32,
    hIcon: ?HICON,
    szTip: [128]u16,
    dwState: u32,
    dwStateMask: u32,
    szInfo: [256]u16,
    uTimeoutOrVersion: u32,
    szInfoTitle: [64]u16,
    dwInfoFlags: u32,
    guidItem: GUID,
    hBalloonIcon: ?HICON,
};

const INITCOMMONCONTROLSEX = extern struct {
    dwSize: u32,
    dwICC: u32,
};

const TIMERPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) void;

// ---------------------------------------------------------------------------
// Win32 imports
// ---------------------------------------------------------------------------

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn GetProcAddress(hModule: HINSTANCE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: u32,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn SendMessageW(?HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) BOOL;
extern "user32" fn MoveWindow(HWND, i32, i32, i32, i32, BOOL) callconv(.winapi) BOOL;
extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
extern "user32" fn LoadImageW(
    hInst: ?HINSTANCE,
    name: *const anyopaque,
    type: u32,
    cx: i32,
    cy: i32,
    fuLoad: u32,
) callconv(.winapi) ?HICON;
extern "user32" fn LoadIconW(hInst: ?HINSTANCE, name: *const anyopaque) callconv(.winapi) ?HICON;
extern "user32" fn LoadCursorW(hInst: ?HINSTANCE, name: *const anyopaque) callconv(.winapi) ?HCURSOR;
extern "user32" fn RegisterWindowMessageW([*:0]const u16) callconv(.winapi) u32;
extern "user32" fn SetTimer(?HWND, usize, u32, ?TIMERPROC) callconv(.winapi) usize;
extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
extern "user32" fn MonitorFromPoint(POINT, u32) callconv(.winapi) ?HMONITOR;
extern "user32" fn GetMonitorInfoW(?HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;

extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const WM_DESTROY = 0x0002;
const WM_ACTIVATE = 0x0006;
const WM_CLOSE = 0x0010;
const WM_TIMER = 0x0113;
const WM_HSCROLL = 0x0114;
const WM_VSCROLL = 0x0115;
const WM_USER = 0x0400;
const WM_TRAYICON = WM_USER + 1;
const WM_LBUTTONDOWN = 0x0201;
const WM_RBUTTONDOWN = 0x0204;

const WA_INACTIVE = 0;

const WS_OVERLAPPED = 0x00000000;
const WS_POPUP = 0x80000000;
const WS_CHILD = 0x40000000;
const WS_VISIBLE = 0x10000000;
const WS_BORDER = 0x00800000;

const WS_EX_TOPMOST = 0x00000008;
const WS_EX_TOOLWINDOW = 0x00000080;

const SW_HIDE = 0;
const SW_SHOW = 5;

const NIM_ADD = 0x00000000;
const NIM_DELETE = 0x00000002;

const NIF_MESSAGE = 0x00000001;
const NIF_ICON = 0x00000002;
const NIF_TIP = 0x00000004;

const IMAGE_ICON = 1;
const LR_DEFAULTCOLOR = 0x00000000;
const IDI_APPLICATION: usize = 32512;
const IDC_ARROW: usize = 32512;

const SM_CXSMICON = 49;
const SM_CYSMICON = 50;

const MONITOR_DEFAULTTONEAREST = 2;

const COLOR_WINDOW_BRUSH = 6; // COLOR_WINDOW + 1

const ICC_STANDARD_CLASSES = 0x00004000;
const ICC_BAR_CLASSES = 0x00000004;

const CLSCTX_INPROC_SERVER = 0x1;
const COINIT_APARTMENTTHREADED = 0x2;

// Trackbar
const TBS_AUTOTICKS = 0x0001;
const TBS_VERT = 0x0002;
const TBS_LEFT = 0x0004;

// The vertical trackbar's value grows downwards. Using a negative range
// (-100 at the top .. 0 at the bottom) makes the top of the slider the loudest
// position, which is what a volume slider is expected to do.
const VOLUME_POS_MIN: i32 = -100;
const VOLUME_POS_MAX: i32 = 0;

const TBM_GETPOS = WM_USER + 0;
const TBM_SETPOS = WM_USER + 5;
const TBM_SETRANGE = WM_USER + 6;
const TBM_SETLINESIZE = WM_USER + 3;
const TBM_SETPAGESIZE = WM_USER + 4;
const TBM_SETTICFREQ = WM_USER + 20;

/// Trackbar range packed as MAKELONG(min, max); the min is a negative SHORT.
const TRACKBAR_RANGE: LPARAM = @as(LPARAM, @as(u16, @bitCast(@as(i16, VOLUME_POS_MIN)))) |
    (@as(LPARAM, @as(u16, @bitCast(@as(i16, VOLUME_POS_MAX)))) << 16);

// ---------------------------------------------------------------------------
// Core Audio COM identifiers
// ---------------------------------------------------------------------------

const CLSID_MMDeviceEnumerator = GUID{
    .data1 = 0xBCDE0395,
    .data2 = 0xE52F,
    .data3 = 0x467C,
    .data4 = .{ 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E },
};

const IID_IMMDeviceEnumerator = GUID{
    .data1 = 0xA95664D2,
    .data2 = 0x9614,
    .data3 = 0x4F35,
    .data4 = .{ 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 },
};

const IID_IAudioEndpointVolume = GUID{
    .data1 = 0x5CDF2C82,
    .data2 = 0x841E,
    .data3 = 0x4546,
    .data4 = .{ 0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A },
};

// EDataFlow::eRender / ERole::eConsole
const E_RENDER = 0;
const E_CONSOLE = 0;

// COM method signatures used through the raw vtables.
const ReleaseFn = *const fn (*anyopaque) callconv(.winapi) u32;
const GetDefaultAudioEndpointFn =
    *const fn (*anyopaque, u32, u32, *?*anyopaque) callconv(.winapi) HRESULT;
const ActivateFn = *const fn (
    *anyopaque,
    *const GUID,
    u32,
    ?*const anyopaque,
    *?*anyopaque,
) callconv(.winapi) HRESULT;
const SetMasterVolumeLevelScalarFn =
    *const fn (*anyopaque, f32, ?*const GUID) callconv(.winapi) HRESULT;
const GetMasterVolumeLevelScalarFn =
    *const fn (*anyopaque, *f32) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("VolumeTrayClass");
const TIMER_ID: usize = 1;
const TIMER_INTERVAL_MS: u32 = 1000;

const POPUP_WIDTH: i32 = 52;
const POPUP_HEIGHT: i32 = 200;
const TRACKBAR_X: i32 = 12;
const TRACKBAR_Y: i32 = 12;
const TRACKBAR_WIDTH: i32 = 30;
const TRACKBAR_HEIGHT: i32 = 176;

var main_hwnd: ?HWND = null;
var popup_hwnd: ?HWND = null;
var trackbar_hwnd: ?HWND = null;

var tray_icon: ?HICON = null;
var tray_added = false;
var taskbar_created_msg: u32 = 0;

var endpoint_volume: ?*anyopaque = null;
var com_ready = false;

/// Throttles COM attempts while the audio service is not available (e.g. when
/// the app is autostarted before the audio stack is up). Dragging the slider
/// must not hammer CoCreateInstance in that situation.
const ACQUIRE_RETRY_MS: u64 = 500;
var acquire_attempted = false;
var last_acquire_ms: u64 = 0;

/// Volume the user asked for while no endpoint was available. It is applied as
/// soon as the audio service becomes usable.
var pending_volume: ?f32 = null;
/// Last volume shown in the UI, used when the system volume cannot be read.
var last_known_volume: f32 = 0.5;

// ---------------------------------------------------------------------------
// COM helpers
// ---------------------------------------------------------------------------

/// Reads a function pointer out of a COM object's vtable.
fn vtableEntry(obj: *anyopaque, comptime Fn: type, index: usize) Fn {
    const object_as_ptr: *const *const usize = @ptrCast(@alignCast(obj));
    const vtable: [*]const usize = @ptrCast(object_as_ptr.*);
    return @ptrFromInt(vtable[index]);
}

fn releaseObject(obj: *anyopaque) void {
    _ = vtableEntry(obj, ReleaseFn, 2)(obj);
}

fn ensureCom() bool {
    if (com_ready) return true;

    const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    // S_OK / S_FALSE / RPC_E_CHANGED_MODE (already initialized on this thread).
    const rpc_e_changed_mode: HRESULT = @bitCast(@as(u32, 0x80010106));
    if (hr >= 0 or hr == rpc_e_changed_mode) {
        com_ready = true;
        return true;
    }
    return false;
}

/// Creates a fresh IAudioEndpointVolume for the current default render device.
/// Returns null when the audio service or a device is not available yet; the
/// caller may retry later (this is what makes early autostart work correctly).
fn acquireEndpoint() ?*anyopaque {
    if (!ensureCom()) return null;

    var enumerator_ptr: ?*anyopaque = null;
    const enum_hr = CoCreateInstance(
        &CLSID_MMDeviceEnumerator,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IMMDeviceEnumerator,
        &enumerator_ptr,
    );
    if (enum_hr < 0) return null;
    const enumerator = enumerator_ptr orelse return null;
    defer releaseObject(enumerator);

    var device_ptr: ?*anyopaque = null;
    const dev_hr = vtableEntry(enumerator, GetDefaultAudioEndpointFn, 4)(
        enumerator,
        E_RENDER,
        E_CONSOLE,
        &device_ptr,
    );
    if (dev_hr < 0) return null;
    const device = device_ptr orelse return null;
    defer releaseObject(device);

    var endpoint_ptr: ?*anyopaque = null;
    const activate_hr = vtableEntry(device, ActivateFn, 3)(
        device,
        &IID_IAudioEndpointVolume,
        CLSCTX_INPROC_SERVER,
        null,
        &endpoint_ptr,
    );
    if (activate_hr < 0) return null;

    return endpoint_ptr;
}

fn dropEndpoint() void {
    if (endpoint_volume) |ep| {
        releaseObject(ep);
        endpoint_volume = null;
    }
}

/// Acquires an endpoint while recording the attempt time (used for backoff).
fn acquireNow() ?*anyopaque {
    acquire_attempted = true;
    last_acquire_ms = GetTickCount64();
    return acquireEndpoint();
}

/// Re-reads the *current* default render device. This keeps the tray in sync
/// when the user switches output devices while the app is running. If the
/// acquisition fails, the previously working endpoint is kept.
fn refreshEndpoint() void {
    if (acquireNow()) |new_endpoint| {
        dropEndpoint();
        endpoint_volume = new_endpoint;
    }
}

fn ensureEndpoint() bool {
    if (endpoint_volume != null) return true;

    // Back off while the audio service is starting up.
    if (acquire_attempted and GetTickCount64() - last_acquire_ms < ACQUIRE_RETRY_MS) {
        return false;
    }

    endpoint_volume = acquireNow();
    return endpoint_volume != null;
}

/// NaN-safe clamp to the valid volume range.
fn clampVolume(volume: f32) f32 {
    if (!(volume > 0.0)) return 0.0; // also catches NaN
    if (volume > 1.0) return 1.0;
    return volume;
}

fn readScalar(ep: *anyopaque, out: *f32) bool {
    return vtableEntry(ep, GetMasterVolumeLevelScalarFn, 9)(ep, out) >= 0;
}

fn writeScalar(ep: *anyopaque, volume: f32) bool {
    return vtableEntry(ep, SetMasterVolumeLevelScalarFn, 7)(ep, volume, null) >= 0;
}

fn getSystemVolume() ?f32 {
    if (!ensureEndpoint()) return null;

    var volume: f32 = 0;
    if (readScalar(endpoint_volume.?, &volume)) {
        return clampVolume(volume);
    }

    // The cached endpoint is stale (device removed / service restarted).
    dropEndpoint();
    endpoint_volume = acquireNow();
    if (endpoint_volume) |ep| {
        if (readScalar(ep, &volume)) {
            return clampVolume(volume);
        }
    }
    return null;
}

fn applyVolume(volume: f32) bool {
    const clamped = clampVolume(volume);

    if (!ensureEndpoint()) return false;

    if (writeScalar(endpoint_volume.?, clamped)) return true;

    // Stale endpoint: drop it, re-acquire the default device and retry once.
    dropEndpoint();
    endpoint_volume = acquireNow();
    if (endpoint_volume) |ep| {
        return writeScalar(ep, clamped);
    }
    return false;
}

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------

fn integerResource(id: usize) *const anyopaque {
    return @ptrFromInt(id);
}

fn loadTrayIcon(hinst: HINSTANCE) ?HICON {
    const cx = GetSystemMetrics(SM_CXSMICON);
    const cy = GetSystemMetrics(SM_CYSMICON);
    if (LoadImageW(hinst, integerResource(1), IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR)) |icon| {
        return icon;
    }
    return LoadIconW(null, integerResource(IDI_APPLICATION));
}

fn addTrayIcon() bool {
    const main_window = main_hwnd orelse return false;

    var nid = std.mem.zeroes(NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(NOTIFYICONDATAW);
    nid.hWnd = main_window;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon = tray_icon;

    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Classic Volume Tray");
    @memcpy(nid.szTip[0..tip.len], tip);

    tray_added = Shell_NotifyIconW(NIM_ADD, &nid) != 0;
    return tray_added;
}

fn removeTrayIcon() void {
    const main_window = main_hwnd orelse return;

    var nid = std.mem.zeroes(NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(NOTIFYICONDATAW);
    nid.hWnd = main_window;
    nid.uID = 1;

    _ = Shell_NotifyIconW(NIM_DELETE, &nid);
    tray_added = false;
}

fn volumeToPos(volume: f32) i32 {
    // Top of the slider (most negative) is the loudest position.
    return -@as(i32, @intFromFloat(clampVolume(volume) * 100.0 + 0.5));
}

fn posToVolume(pos: i32) f32 {
    const clamped = std.math.clamp(pos, VOLUME_POS_MIN, VOLUME_POS_MAX);
    return @as(f32, @floatFromInt(-clamped)) / 100.0;
}

fn showPopup() void {
    const popup = popup_hwnd orelse return;
    const trackbar = trackbar_hwnd orelse return;

    // Always talk to the device that is the default *right now*.
    refreshEndpoint();

    var cursor: POINT = undefined;
    _ = GetCursorPos(&cursor);

    var x = cursor.x - @divTrunc(POPUP_WIDTH, 2);
    var y = cursor.y - POPUP_HEIGHT - 8;

    const monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    var info = MONITORINFO{
        .cbSize = @sizeOf(MONITORINFO),
        .rcMonitor = std.mem.zeroes(RECT),
        .rcWork = std.mem.zeroes(RECT),
        .dwFlags = 0,
    };
    if (GetMonitorInfoW(monitor, &info) != 0) {
        const work = info.rcWork;
        if (x + POPUP_WIDTH > work.right) x = work.right - POPUP_WIDTH;
        if (x < work.left) x = work.left;
        if (y + POPUP_HEIGHT > work.bottom) y = work.bottom - POPUP_HEIGHT;
        if (y < work.top) y = work.top;
    }

    _ = MoveWindow(popup, x, y, POPUP_WIDTH, POPUP_HEIGHT, 1);

    const volume = getSystemVolume() orelse last_known_volume;
    last_known_volume = volume;
    const pos = volumeToPos(volume);
    _ = SendMessageW(trackbar, TBM_SETPOS, 1, @as(LPARAM, pos));

    _ = ShowWindow(popup, SW_SHOW);
    _ = SetForegroundWindow(popup);
}

fn togglePopup() void {
    const popup = popup_hwnd orelse return;

    if (IsWindowVisible(popup) != 0) {
        _ = ShowWindow(popup, SW_HIDE);
        return;
    }
    showPopup();
}

// ---------------------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------------------

fn wndProc(hwnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (taskbar_created_msg != 0 and msg == taskbar_created_msg) {
        // Explorer restarted: the tray icon has to be registered again.
        tray_added = false;
        _ = addTrayIcon();
        return 0;
    }

    switch (msg) {
        WM_TRAYICON => {
            const mouse_msg = @as(u32, @truncate(@as(usize, @bitCast(lParam))));
            if (mouse_msg == WM_LBUTTONDOWN or mouse_msg == WM_RBUTTONDOWN) {
                togglePopup();
            }
            return 0;
        },
        WM_VSCROLL, WM_HSCROLL => {
            if (trackbar_hwnd) |trackbar| {
                const raw_pos: i32 = @intCast(SendMessageW(trackbar, TBM_GETPOS, 0, 0));
                const volume = posToVolume(raw_pos);
                last_known_volume = volume;

                if (applyVolume(volume)) {
                    pending_volume = null;
                } else {
                    // Audio service not ready yet: remember the intent and let
                    // the timer apply it once the endpoint becomes available.
                    pending_volume = volume;
                }
            }
            return 0;
        },
        WM_ACTIVATE => {
            if (wParam == WA_INACTIVE) {
                if (popup_hwnd) |popup| {
                    _ = ShowWindow(popup, SW_HIDE);
                }
            }
        },
        WM_TIMER => {
            if (wParam == TIMER_ID) {
                if (!tray_added) {
                    _ = addTrayIcon();
                }

                if (endpoint_volume == null) {
                    if (acquireNow()) |ep| {
                        endpoint_volume = ep;
                        if (pending_volume) |volume| {
                            if (writeScalar(ep, volume)) pending_volume = null;
                        }
                    }
                }

                if (tray_added and endpoint_volume != null) {
                    _ = KillTimer(hwnd, TIMER_ID);
                }
                return 0;
            }
        },
        WM_CLOSE => {
            _ = ShowWindow(hwnd, SW_HIDE);
            return 0;
        },
        WM_DESTROY => {
            _ = KillTimer(hwnd, TIMER_ID);
            removeTrayIcon();
            dropEndpoint();
            PostQuitMessage(0);
            return 0;
        },
        else => {},
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() void {
    const hinst = GetModuleHandleW(null) orelse return;

    _ = InitCommonControlsEx(&.{
        .dwSize = @sizeOf(INITCOMMONCONTROLSEX),
        .dwICC = ICC_BAR_CLASSES | ICC_STANDARD_CLASSES,
    });

    _ = ensureCom();
    // Do not fail here: at logon the audio service may still be starting. The
    // endpoint is acquired lazily and retried by the timer below.
    endpoint_volume = acquireNow();

    tray_icon = loadTrayIcon(hinst);

    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.hIcon = tray_icon;
    wc.hIconSm = tray_icon;
    wc.hCursor = LoadCursorW(null, integerResource(IDC_ARROW));
    wc.hbrBackground = @ptrFromInt(COLOR_WINDOW_BRUSH);
    wc.lpszClassName = CLASS_NAME;

    if (RegisterClassExW(&wc) == 0) return;

    main_hwnd = CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Volume Tray"),
        WS_OVERLAPPED,
        0,
        0,
        0,
        0,
        null,
        null,
        hinst,
        null,
    ) orelse return;

    popup_hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        CLASS_NAME,
        null,
        WS_POPUP | WS_BORDER,
        0,
        0,
        POPUP_WIDTH,
        POPUP_HEIGHT,
        main_hwnd,
        null,
        hinst,
        null,
    ) orelse return;

    trackbar_hwnd = CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("msctls_trackbar32"),
        null,
        WS_CHILD | WS_VISIBLE | TBS_VERT | TBS_AUTOTICKS | TBS_LEFT,
        TRACKBAR_X,
        TRACKBAR_Y,
        TRACKBAR_WIDTH,
        TRACKBAR_HEIGHT,
        popup_hwnd,
        null,
        hinst,
        null,
    ) orelse return;

    _ = SendMessageW(trackbar_hwnd.?, TBM_SETRANGE, 1, TRACKBAR_RANGE);
    _ = SendMessageW(trackbar_hwnd.?, TBM_SETLINESIZE, 0, 5);
    _ = SendMessageW(trackbar_hwnd.?, TBM_SETPAGESIZE, 0, 10);

    _ = addTrayIcon();

    taskbar_created_msg = RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));

    // Safety net for logon autostart: retry the audio endpoint / tray icon
    // until both are ready, then stop the timer.
    _ = SetTimer(main_hwnd.?, TIMER_ID, TIMER_INTERVAL_MS, null);

    var msg: MSG = undefined;
    while (true) {
        const result = GetMessageW(&msg, null, 0, 0);
        if (result <= 0) break; // 0 = WM_QUIT, -1 = error
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    dropEndpoint();
}
