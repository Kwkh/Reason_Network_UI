// Debug 构建也不弹控制台窗口；需要在终端看 Rust 日志时临时删掉这一行。
#![windows_subsystem = "windows"]

fn main() {
    reason_network_windows_lib::run();
}
