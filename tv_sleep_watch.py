"""Background listener: turn the TV off when Windows goes to sleep.

Run at logon with pythonw.exe (no console window). Windows only gives
apps ~2 s after the suspend notification, so the off path uses short
timeouts.
"""
import ctypes
import ctypes.wintypes as w

from tv_power import log, turn_off

WM_POWERBROADCAST = 0x0218
PBT_APMSUSPEND = 0x0004

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

LRESULT = ctypes.c_ssize_t
WNDPROC = ctypes.WINFUNCTYPE(LRESULT, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

user32.DefWindowProcW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
user32.DefWindowProcW.restype = LRESULT
user32.CreateWindowExW.argtypes = [
    w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, ctypes.c_int, ctypes.c_int,
    ctypes.c_int, ctypes.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID,
]
user32.CreateWindowExW.restype = w.HWND
user32.GetMessageW.argtypes = [ctypes.POINTER(w.MSG), w.HWND, w.UINT, w.UINT]
kernel32.GetModuleHandleW.restype = w.HMODULE


class WNDCLASSW(ctypes.Structure):
    _fields_ = [
        ("style", w.UINT),
        ("lpfnWndProc", WNDPROC),
        ("cbClsExtra", ctypes.c_int),
        ("cbWndExtra", ctypes.c_int),
        ("hInstance", w.HINSTANCE),
        ("hIcon", w.HICON),
        ("hCursor", w.HANDLE),
        ("hbrBackground", w.HBRUSH),
        ("lpszMenuName", w.LPCWSTR),
        ("lpszClassName", w.LPCWSTR),
    ]


def wndproc(hwnd, msg, wparam, lparam):
    if msg == WM_POWERBROADCAST and wparam == PBT_APMSUSPEND:
        log.info("Suspend detected")
        try:
            turn_off(connect_timeout=1.5, state_timeout=1.0)
        except Exception:
            log.exception("off on suspend failed")
        return 1
    return user32.DefWindowProcW(hwnd, msg, wparam, lparam)


def main():
    proc = WNDPROC(wndproc)  # keep a reference so it isn't garbage-collected
    hinst = kernel32.GetModuleHandleW(None)
    wc = WNDCLASSW(lpfnWndProc=proc, hInstance=hinst, lpszClassName="TvSleepWatch")
    if not user32.RegisterClassW(ctypes.byref(wc)):
        raise ctypes.WinError(ctypes.get_last_error())
    # A hidden top-level window: message-only windows don't get WM_POWERBROADCAST.
    hwnd = user32.CreateWindowExW(0, "TvSleepWatch", "TvSleepWatch", 0,
                                  0, 0, 0, 0, None, None, hinst, None)
    if not hwnd:
        raise ctypes.WinError(ctypes.get_last_error())
    log.info("Sleep watcher started")

    msg = w.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        user32.TranslateMessage(ctypes.byref(msg))
        user32.DispatchMessageW(ctypes.byref(msg))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log.exception("Sleep watcher crashed")
        raise
