//! Windows 窗口置顶：按标题找到子窗口 HWND 并设为 TOPMOST

use std::ffi::c_char;
use windows::Win32::Foundation::{BOOL, HWND, LPARAM};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowTextW, SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE,
    SWP_NOSIZE, SWP_SHOWWINDOW,
};

struct Ctx {
    name: String,
    found: Option<HWND>,
}

unsafe extern "system" fn enum_cb(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let ctx = &mut *(lparam.0 as *mut Ctx);
    let mut buf = [0u16; 512];
    let len = unsafe { GetWindowTextW(hwnd, &mut buf) };
    if len > 0 {
        let text = String::from_utf16_lossy(&buf[..len as usize]);
        if text == ctx.name {
            ctx.found = Some(hwnd);
            return BOOL(0);
        }
    }
    BOOL(1)
}

#[no_mangle]
pub extern "C" fn set_topmost(title: *const c_char, buf: *mut u8, len: usize) -> i32 {
    crate::ffi_guard!(buf, len, {
        let Some(name) = crate::cstr(title) else {
            return crate::fail(buf, len, -1, "标题为空");
        };

        let mut ctx = Ctx { name, found: None };
        unsafe {
            let _ = EnumWindows(Some(enum_cb), LPARAM(&mut ctx as *mut Ctx as isize));
        }

        match ctx.found {
            Some(hwnd) => {
                let r = unsafe {
                    SetWindowPos(
                        hwnd,
                        HWND_TOPMOST,
                        0,
                        0,
                        0,
                        0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW,
                    )
                };
                if r.is_ok() {
                    crate::ok(buf, len, "已置顶", serde_json::json!({"title": ctx.name}))
                } else {
                    crate::fail(buf, len, -3, "置顶失败")
                }
            }
            None => crate::fail(buf, len, -3, "未找到目标窗口"),
        }
    })
}
