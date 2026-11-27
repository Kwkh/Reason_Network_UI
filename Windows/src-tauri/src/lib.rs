use tauri::{LogicalSize, Manager};

mod attachments;
mod backend;
mod store;
mod types;

/// 未安装的 debug/release 构建没有 Start Menu 快捷方式；显式设置 AppUserModelID，
/// 让 Windows 系统通知在开发环境也能归属到本应用。
#[cfg(windows)]
fn set_app_user_model_id() {
    use windows_sys::Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID;
    let id: Vec<u16> = "network.reason.windows\0".encode_utf16().collect();
    // SAFETY: id 以 NUL 结尾且在调用期间保持存活。
    unsafe {
        let _ = SetCurrentProcessExplicitAppUserModelID(id.as_ptr());
    }
}

pub fn run() {
    #[cfg(windows)]
    set_app_user_model_id();
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            // Windows 高 DPI 下初始窗口可能按物理像素创建，导致 WebView 视口偏小。
            // 这里按逻辑像素再设置一次，保证 150%/200% 缩放时布局宽度仍是 940。
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_size(LogicalSize::new(940.0, 780.0));
                let _ = window.set_min_size(Some(tauri::Size::Logical(LogicalSize::new(
                    760.0, 560.0,
                ))));
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            backend::list_networks,
            backend::snapshot,
            backend::send_message,
            backend::inspect_attachments,
            backend::attachment_text,
            backend::save_attachment,
            backend::join_network,
            backend::create_network,
            backend::network_link,
            backend::native_catalog,
            backend::open_data_folder,
        ])
        .run(tauri::generate_context!())
        .expect("运行 Reason Network Windows 客户端失败");
}
