use tauri::{LogicalSize, Manager};

mod attachments;
mod backend;
mod store;
mod types;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
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
