fn main() {
    // 默认清单没有 DPI 感知；Windows 高分屏下 WebView 视口会偏小并裁切。
    tauri_build::try_build(
        tauri_build::Attributes::new().windows_attributes(
            tauri_build::WindowsAttributes::new().app_manifest(include_str!("windows-app-manifest.xml")),
        ),
    )
    .expect("运行 tauri-build 失败");
}
