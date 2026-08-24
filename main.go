package main

import (
	_ "embed"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

//go:embed icon_32x32.ico
var icon []byte

// Win32 常量定义
const (
	WM_DESTROY     = 0x0002
	WM_CREATE      = 0x0001
	WM_HSCROLL     = 0x0114
	WM_ACTIVATE    = 0x0006
	WA_INACTIVE    = 0
	WM_USER        = 0x0400
	WM_TRAYICON    = WM_USER + 1
	WM_LBUTTONDOWN = 0x0201
	WM_RBUTTONDOWN = 0x0204

	NIM_ADD     = 0x00000000
	NIM_DELETE  = 0x00000002
	NIF_MESSAGE = 0x00000001
	NIF_ICON    = 0x00000002
	NIF_TIP     = 0x00000004

	IDI_APPLICATION  = 32512
	WS_OVERLAPPED    = 0x00000000
	WS_POPUP         = 0x80000000
	WS_VISIBLE       = 0x10000000
	WS_CHILD         = 0x40000000
	WS_EX_TOPMOST    = 0x00000008
	WS_EX_TOOLWINDOW = 0x00000080

	TBS_HORZ      = 0x0000
	TBS_AUTOTICKS = 0x0001

	TBM_SETPOS   = WM_USER + 5
	TBM_GETPOS   = WM_USER + 0
	TBM_SETRANGE = WM_USER + 6

	CLSCTX_INPROC_SERVER = 0x1
)

type NOTIFYICONDATA struct {
	CbSize            uint32
	HWnd              uintptr
	UID               uint32
	UFlags            uint32
	UCallbackMessage  uint32
	HIcon             uintptr
	SzTip             [128]uint16
	DwState           uint32
	DwStateMask       uint32
	SzInfo            [256]uint16
	UTimeoutOrVersion uint32
	SzInfoTitle       [64]uint16
	DwInfoFlags       uint32
	GuidItem          [16]byte
	HBalloonIcon      uintptr
}

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	ole32    = syscall.NewLazyDLL("ole32.dll")
	comctl32 = syscall.NewLazyDLL("comctl32.dll")

	procRegisterClassEx  = user32.NewProc("RegisterClassExW")
	procCreateWindowEx   = user32.NewProc("CreateWindowExW")
	procDefWindowProc    = user32.NewProc("DefWindowProcW")
	procGetMessage       = user32.NewProc("GetMessageW")
	procTranslateMessage = user32.NewProc("TranslateMessage")
	procDispatchMessage  = user32.NewProc("DispatchMessageW")
	procPostQuitMessage  = user32.NewProc("PostQuitMessage")
	procLoadIcon         = user32.NewProc("LoadIconW")
	procGetCursorPos     = user32.NewProc("GetCursorPos")
	procSetForegroundWin = user32.NewProc("SetForegroundWindow")
	procShowWindow       = user32.NewProc("ShowWindow")
	procSendMessage      = user32.NewProc("SendMessageW")
	procMoveWindow       = user32.NewProc("MoveWindow")

	procShellNotifyIcon    = shell32.NewProc("Shell_NotifyIconW")
	procInitCommonControls = comctl32.NewProc("InitCommonControls")

	procCoInitializeEx   = ole32.NewProc("CoInitializeEx")
	procCoCreateInstance = ole32.NewProc("CoCreateInstance")

	procCreateIconFromResourceEx = user32.NewProc("CreateIconFromResourceEx")
)

type POINT struct {
	X, Y int32
}

type WNDCLASSEX struct {
	CbSize        uint32
	Style         uint32
	PfnWndProc    uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     uintptr
	HIcon         uintptr
	HCursor       uintptr
	HbrBackground uintptr
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       uintptr
}

// Core Audio GUID 定义
var (
	CLSID_MMDeviceEnumerator = syscall.GUID{Data1: 0xBCDE0395, Data2: 0xE52F, Data3: 0x467C, Data4: [8]byte{0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
	IID_IMMDeviceEnumerator  = syscall.GUID{Data1: 0xA95664D2, Data2: 0x9614, Data3: 0x4F35, Data4: [8]byte{0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
	IID_IAudioEndpointVolume = syscall.GUID{Data1: 0x5CDF2C82, Data2: 0x841E, Data3: 0x4546, Data4: [8]byte{0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A}}
)

// COM 接口虚函数表解引用辅助方法
func callMethod(vtable uintptr, index int, args ...uintptr) uintptr {
	// 获取 vtable 的方法指针列表
	methodPtr := *(*uintptr)(unsafe.Pointer(vtable + uintptr(index)*unsafe.Sizeof(uintptr(0))))
	ret, _, _ := syscall.SyscallN(methodPtr, args...)
	return ret
}

var endpointVolume uintptr // IAudioEndpointVolume* 接口指针
var popupHWnd uintptr
var trackbarHWnd uintptr

// 初始化 COM 音频设备
func initAudio() error {
	// 0x0 = COINIT_APARTMENTTHREADED
	procCoInitializeEx.Call(0, 0)

	var enumerator uintptr
	hr, _, _ := procCoCreateInstance.Call(
		uintptr(unsafe.Pointer(&CLSID_MMDeviceEnumerator)),
		0,
		CLSCTX_INPROC_SERVER,
		uintptr(unsafe.Pointer(&IID_IMMDeviceEnumerator)),
		uintptr(unsafe.Pointer(&enumerator)),
	)
	if hr != 0 || enumerator == 0 {
		return fmt.Errorf("CoCreateInstance 失败: 0x%x", hr)
	}

	// IMMDeviceEnumerator::GetDefaultAudioEndpoint 对应虚函数表 index 4 (0:QueryInterface, 1:AddRef, 2:Release, 3:EnumAudioEndpoints, 4:GetDefaultAudioEndpoint)
	var device uintptr
	enumVtbl := *(*uintptr)(unsafe.Pointer(enumerator))
	hr = callMethod(enumVtbl, 4, enumerator, 0 /*eRender*/, 0 /*eMultimedia*/, uintptr(unsafe.Pointer(&device)))
	if hr != 0 || device == 0 {
		return fmt.Errorf("GetDefaultAudioEndpoint 失败: 0x%x", hr)
	}

	// IMMDevice::Activate 对应虚函数表 index 3 (0:QueryInterface, 1:AddRef, 2:Release, 3:Activate)
	devVtbl := *(*uintptr)(unsafe.Pointer(device))
	hr = callMethod(devVtbl, 3, device, uintptr(unsafe.Pointer(&IID_IAudioEndpointVolume)), CLSCTX_INPROC_SERVER, 0, uintptr(unsafe.Pointer(&endpointVolume)))
	if hr != 0 || endpointVolume == 0 {
		return fmt.Errorf("IAudioEndpointVolume Activate 失败: 0x%x", hr)
	}

	return nil
}

func setVolume(percent float32) {
	if endpointVolume == 0 {
		return
	}
	// IAudioEndpointVolume::SetMasterVolumeLevelScalar 对应虚函数表 index 7
	volVtbl := *(*uintptr)(unsafe.Pointer(endpointVolume))
	// 将 float32 转成 uintptr 传入
	bits := *(*uint32)(unsafe.Pointer(&percent))
	callMethod(volVtbl, 7, endpointVolume, uintptr(bits), 0)
}

func getVolume() float32 {
	if endpointVolume == 0 {
		return 0.5
	}
	// IAudioEndpointVolume::GetMasterVolumeLevelScalar 对应虚函数表 index 9
	var vol float32
	volVtbl := *(*uintptr)(unsafe.Pointer(endpointVolume))
	callMethod(volVtbl, 9, endpointVolume, uintptr(unsafe.Pointer(&vol)))
	return vol
}

func wndProc(hwnd uintptr, msg uint32, wParam, lParam uintptr) uintptr {
	switch msg {
	case WM_TRAYICON:
		if lParam == WM_LBUTTONDOWN || lParam == WM_RBUTTONDOWN {
			toggleVolumePopup()
		}
	case WM_HSCROLL:
		pos, _, _ := procSendMessage.Call(trackbarHWnd, TBM_GETPOS, 0, 0)
		vol := float32(pos) / 100.0
		setVolume(vol)
	case WM_ACTIVATE:
		if wParam == WA_INACTIVE {
			procShowWindow.Call(popupHWnd, 0) // SW_HIDE
		}
	case WM_DESTROY:
		procPostQuitMessage.Call(0)
		return 0
	}
	ret, _, _ := procDefWindowProc.Call(hwnd, uintptr(msg), wParam, lParam)
	return ret
}

func toggleVolumePopup() {
	var pt POINT
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))

	currentVol := int(getVolume() * 100)
	procSendMessage.Call(trackbarHWnd, TBM_SETPOS, 1, uintptr(currentVol))

	procMoveWindow.Call(popupHWnd, uintptr(pt.X-100), uintptr(pt.Y-60), 200, 50, 1)
	procShowWindow.Call(popupHWnd, 5) // SW_SHOW
	procSetForegroundWin.Call(popupHWnd)
}

func main() {
	runtime.LockOSThread()

	procInitCommonControls.Call()

	if err := initAudio(); err != nil {
		fmt.Println("音频组件初始化失败:", err)
		return
	}

	className, _ := syscall.UTF16PtrFromString("VolumeTrayClass")
	hIcon := createIconFromBytes(icon)
	if hIcon == 0 {
		// 保底：如果 ico 解析失败，回退到系统默认应用程序图标
		hIcon, _, _ = procLoadIcon.Call(0, uintptr(IDI_APPLICATION))
	}

	var wc WNDCLASSEX
	wc.CbSize = uint32(unsafe.Sizeof(wc))
	wc.PfnWndProc = syscall.NewCallback(wndProc)
	wc.LpszClassName = className
	wc.HIcon = hIcon
	wc.HbrBackground = 5

	procRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc)))

	mainHWnd, _, _ := procCreateWindowEx.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr("Volume Tray"))),
		WS_OVERLAPPED,
		0, 0, 0, 0,
		0, 0, 0, 0,
	)

	popupHWnd, _, _ = procCreateWindowEx.Call(
		WS_EX_TOPMOST|WS_EX_TOOLWINDOW,
		uintptr(unsafe.Pointer(className)),
		0,
		WS_POPUP,
		0, 0, 200, 50,
		mainHWnd, 0, 0, 0,
	)

	trackbarClass, _ := syscall.UTF16PtrFromString("msctls_trackbar32")
	trackbarHWnd, _, _ = procCreateWindowEx.Call(
		0,
		uintptr(unsafe.Pointer(trackbarClass)),
		0,
		WS_CHILD|WS_VISIBLE|TBS_HORZ|TBS_AUTOTICKS,
		10, 10, 180, 30,
		popupHWnd, 0, 0, 0,
	)

	procSendMessage.Call(trackbarHWnd, TBM_SETRANGE, 1, uintptr(100<<16|(0&0xFFFF)))

	var nid NOTIFYICONDATA
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	nid.HWnd = mainHWnd
	nid.UID = 1
	nid.UFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP
	nid.UCallbackMessage = WM_TRAYICON
	nid.HIcon = hIcon

	tip, _ := syscall.UTF16FromString("Classic Volume Tray")
	copy(nid.SzTip[:], tip)

	procShellNotifyIcon.Call(NIM_ADD, uintptr(unsafe.Pointer(&nid)))

	defer func() {
		procShellNotifyIcon.Call(NIM_DELETE, uintptr(unsafe.Pointer(&nid)))
	}()

	var msg struct {
		HWnd    uintptr
		Message uint32
		WParam  uintptr
		LParam  uintptr
		Time    uint32
		Pt      POINT
	}

	for {
		res, _, _ := procGetMessage.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if res == 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&msg)))
		procDispatchMessage.Call(uintptr(unsafe.Pointer(&msg)))
	}
}

// 将内嵌的 ico []byte 转换为 Win32 HICON 图标句柄
func createIconFromBytes(data []byte) uintptr {
	if len(data) == 0 {
		return 0
	}

	// 1. 解析 .ico 文件的 Header，获取第一个 Image 的数据偏移量及大小
	// .ico 文件格式：[0..3] 保留/类型, [4..5] 图像数量, [6..21] 图像1的 Directory Entry
	if len(data) < 22 {
		return 0
	}
	bytesInRes := *(*uint32)(unsafe.Pointer(&data[14]))  // 图像数据大小
	imageOffset := *(*uint32)(unsafe.Pointer(&data[18])) // 数据起始偏移量

	if uint32(len(data)) < imageOffset+bytesInRes {
		return 0
	}

	// 截取图标图像纯数据
	rawImage := data[imageOffset : imageOffset+bytesInRes]

	// 2. 调用 CreateIconFromResourceEx 生成 HICON
	hIcon, _, _ := procCreateIconFromResourceEx.Call(
		uintptr(unsafe.Pointer(&rawImage[0])),
		uintptr(len(rawImage)),
		1,          // fIcon: TRUE (1 表示 Icon, 0 表示 Cursor)
		0x00030000, // dwVersion: 默认 0x00030000
		0, 0,       // cxDesired, cyDesired: 0 表示使用默认尺寸
		0x00000000, // Flags: LR_DEFAULTCOLOR
	)

	return hIcon
}
