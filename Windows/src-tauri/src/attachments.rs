//! 附件校验、读取与另存。
//!
//! 规则与 macOS 客户端一致：只接受 UTF-8 文本，单个不超过 256 KiB，
//! 每条消息最多 10 个、合计不超过 512 KiB。收件箱目录来自引擎生成的
//! 26 位 Crockford Base32，读取前必须防止路径穿越。

use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use crate::types::AttachmentDraft;

pub const MAX_FILES: usize = 10;
pub const MAX_FILE_BYTES: usize = 256 * 1024;
pub const MAX_TOTAL_BYTES: usize = 512 * 1024;

fn file_name(path: &Path) -> Result<String, String> {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("无法识别附件文件名：{}", path.display()))
}

/// 读取并校验一个文本文件；错误信息直接面向界面。
fn read_text(path: &Path) -> Result<String, String> {
    let name = file_name(path)?;
    let meta = fs::metadata(path).map_err(|_| format!("{name}：请选择普通文本文件。"))?;
    if !meta.is_file() {
        return Err(format!("{name}：请选择普通文本文件。"));
    }
    let file = fs::File::open(path).map_err(|error| format!("{name}：无法读取（{error}）"))?;
    let mut data = Vec::new();
    file.take(MAX_FILE_BYTES as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|error| format!("{name}：无法读取（{error}）"))?;
    if data.len() > MAX_FILE_BYTES {
        return Err(format!("{name}：每个附件须为不超过 256 KiB 的 UTF-8 文本。"));
    }
    let text = String::from_utf8(data)
        .map_err(|_| format!("{name}：每个附件须为不超过 256 KiB 的 UTF-8 文本。"))?;
    // 与 macOS 的 MessageAttachment.text(at:) 一致：拒绝不可见的 C0/C1 控制字符。
    if text
        .chars()
        .any(|ch| ch.is_control() && (ch as u32) < 160 && !matches!(ch, '\t' | '\n' | '\r'))
    {
        return Err(format!("{name}：每个附件须为不超过 256 KiB 的 UTF-8 文本。"));
    }
    Ok(text)
}

/// 选择后立即校验，前端据此展示附件 chips；发送时会再校验一次。
pub fn inspect(paths: &[String]) -> Result<Vec<AttachmentDraft>, String> {
    if paths.len() > MAX_FILES {
        return Err("每条消息最多添加 10 个附件。".into());
    }
    let mut total = 0usize;
    let mut drafts = Vec::with_capacity(paths.len());
    for raw in paths {
        let path = PathBuf::from(raw);
        let text = read_text(&path)?;
        total += text.len();
        if total > MAX_TOTAL_BYTES {
            return Err("附件合计不能超过 512 KiB。".into());
        }
        drafts.push(AttachmentDraft {
            path: raw.clone(),
            name: file_name(&path)?,
            size: text.len() as u64,
        });
    }
    Ok(drafts)
}

/// 校验来信附件的目录名与文件名，返回规范化后的真实路径。
fn inbox_file(home: &Path, directory: &str, name: &str) -> Result<PathBuf, String> {
    let valid_dir = directory.len() == 26
        && directory.chars().all(|ch| {
            matches!(ch,
                '0'..='9' | 'A'..='H' | 'J' | 'K' | 'M' | 'N' | 'P'..='T' | 'V'..='Z')
        });
    if !valid_dir {
        return Err("附件位置不可用。".into());
    }
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.contains('\0')
    {
        return Err("附件位置不可用。".into());
    }
    let mut components = Path::new(name).components();
    if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
        return Err("附件位置不可用。".into());
    }

    let root = home.join("inbox");
    let dir = root.join(directory);
    let file = dir.join(name);
    let canonical_root = root
        .canonicalize()
        .map_err(|_| "附件已过期或无法读取。".to_string())?;
    let canonical_dir = dir
        .canonicalize()
        .map_err(|_| "附件已过期或无法读取。".to_string())?;
    let canonical_file = file
        .canonicalize()
        .map_err(|_| "附件已过期或无法读取。".to_string())?;
    // canonicalize 会展开符号链接；逃出收件箱的链接在这里被拒绝。
    if !canonical_dir.starts_with(&canonical_root)
        || canonical_file.parent() != Some(canonical_dir.as_path())
    {
        return Err("附件已过期或无法读取。".into());
    }
    if !fs::metadata(&canonical_file)
        .map(|meta| meta.is_file())
        .unwrap_or(false)
    {
        return Err("附件已过期或无法读取。".into());
    }
    Ok(canonical_file)
}

pub fn read_attachment(home: &Path, directory: &str, name: &str) -> Result<String, String> {
    let path = inbox_file(home, directory, name)?;
    read_text(&path)
}

pub fn save_attachment(
    home: &Path,
    directory: &str,
    name: &str,
    target: &str,
) -> Result<(), String> {
    if target.trim().is_empty() {
        return Err("请选择保存位置".into());
    }
    let source = inbox_file(home, directory, name)?;
    read_text(&source)?;
    let target = PathBuf::from(target);
    if let Some(parent) = target.parent().filter(|path| !path.as_os_str().is_empty()) {
        if !parent.is_dir() {
            return Err(format!("保存目录不存在：{}", parent.display()));
        }
    }
    fs::copy(&source, &target).map_err(|error| format!("保存附件失败：{error}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "rn-attach-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn inspect_rejects_oversize_and_binary() {
        let root = scratch();
        let big = root.join("big.txt");
        fs::write(&big, vec![b'a'; MAX_FILE_BYTES + 1]).unwrap();
        assert!(inspect(&[big.to_string_lossy().into_owned()]).is_err());

        // 合法 UTF-8，但含不可见控制字符。
        let binary = root.join("bin.dat");
        fs::write(&binary, b"abc\x01def").unwrap();
        assert!(inspect(&[binary.to_string_lossy().into_owned()]).is_err());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn inspect_accepts_utf8_text() {
        let root = scratch();
        let file = root.join("note.txt");
        fs::write(&file, "你好\nreason").unwrap();
        let drafts = inspect(&[file.to_string_lossy().into_owned()]).unwrap();
        assert_eq!(drafts.len(), 1);
        assert_eq!(drafts[0].name, "note.txt");
        assert_eq!(drafts[0].size, "你好\nreason".len() as u64);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn inbox_rejects_traversal() {
        let root = scratch();
        let dir = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
        fs::create_dir_all(root.join("inbox").join(dir)).unwrap();
        fs::write(root.join("inbox").join(dir).join("a.txt"), "hi").unwrap();
        assert_eq!(
            read_attachment(&root, dir, "a.txt").unwrap(),
            "hi".to_string()
        );
        assert!(read_attachment(&root, dir, "../a.txt").is_err());
        assert!(read_attachment(&root, dir, "..\\a.txt").is_err());
        assert!(read_attachment(&root, "../../network.db", "a.txt").is_err());
        assert!(read_attachment(&root, "short", "a.txt").is_err());
        let _ = fs::remove_dir_all(&root);
    }
}
