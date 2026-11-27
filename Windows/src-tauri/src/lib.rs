mod backend;
mod store;
mod types;

pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            backend::list_networks,
            backend::snapshot,
            backend::send_message,
            backend::join_network,
            backend::create_network,
            backend::native_catalog,
            backend::open_data_folder,
        ])
        .run(tauri::generate_context!())
        .expect("运行 Reason Network Windows 客户端失败");
}
