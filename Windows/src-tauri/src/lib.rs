use tauri::{LogicalSize, Manager};

mod attachments;
mod backend;
mod daemon_ipc;
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
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            // 安装包把后台放在可执行文件旁的 backend/ 下；开发构建没有这个目录，
            // 会回落到仓库 Engine/Bin。
            // debug 构建（tauri dev / cargo build）始终用仓库后台，避免把工具配置
            // 指向 target\debug 下的临时资源；release/安装包才使用内置后台。
            #[cfg(not(debug_assertions))]
            let bundled = app
                .path()
                .resource_dir()
                .ok()
                .map(|dir| dir.join("backend").join("reason-network-backend.exe"))
                .filter(|path| path.is_file());
            #[cfg(debug_assertions)]
            let bundled = None;
            backend::set_bundled_binary(bundled);

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
            backend::set_session_participation,
            backend::join_session_network,
            backend::invite_code,
            backend::leave_network,
            backend::dissolve_network,
            backend::remove_device,
            backend::set_receive_mode,
            backend::set_sessions_participation,
            backend::enable_workspaces,
            backend::create_workspace,
            backend::join_workspace,
            backend::delete_workspace,
            backend::native_catalog,
            backend::backend_info,
            backend::app_integrations,
            backend::setup_preview,
            backend::setup_configure,
            backend::open_data_folder,
        ])
        .run(tauri::generate_context!())
        .expect("运行 Reason Network Windows 客户端失败");
}
