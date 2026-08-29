use std::collections::HashMap;

use crate::types::Page;

/// One row in the sidebar: either a folder (with children) or a page (a leaf).
///
/// The page store has no folder objects — a "folder" is just a shared path
/// prefix among page paths, exactly as in a git tree. So the tree is derived
/// from the flat page list rather than stored, and an empty folder cannot exist
/// by construction.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct DocNode {
    pub id: String,
    pub name: String,
    pub page: Option<Page>,
    pub children: Option<Vec<DocNode>>,
}

impl DocNode {
    pub fn is_folder(&self) -> bool {
        self.page.is_none()
    }
}

/// Groups pages into a folder hierarchy by splitting their paths.
///
/// `pending_folders` are client-side-only placeholders (see
/// `AppModel.createFolder`) — folder paths, each with a trailing `/`, that
/// don't correspond to any page yet. They're folded in alongside the real ones
/// so a just-created empty folder shows up in the sidebar before it has any
/// content.
#[uniffi::export]
pub fn build_tree(pages: Vec<Page>, pending_folders: Vec<String>) -> Vec<DocNode> {
    let mut pages = pages;
    pages.sort_by(|a, b| a.path.cmp(&b.path));
    build(&pages, &pending_folders, "")
}

fn build(pages: &[Page], pending_folders: &[String], prefix: &str) -> Vec<DocNode> {
    let mut folders: HashMap<String, Vec<Page>> = HashMap::new();
    let mut folder_order: Vec<String> = Vec::new();
    let mut leaves: Vec<DocNode> = Vec::new();

    for page in pages {
        let relative = &page.path[prefix.len()..];
        match relative.split_once('/') {
            None => leaves.push(DocNode {
                id: page.path.clone(),
                name: page.title(),
                page: Some(page.clone()),
                children: None,
            }),
            Some((folder, _)) => {
                let entry = folders.entry(folder.to_string()).or_insert_with(|| {
                    folder_order.push(folder.to_string());
                    Vec::new()
                });
                entry.push(page.clone());
            },
        }
    }

    for pending in pending_folders.iter().filter(|p| p.starts_with(prefix)) {
        let relative = &pending[prefix.len()..];
        if relative.is_empty() {
            continue;
        }
        let folder = relative.split('/').next().unwrap_or(relative);
        folders.entry(folder.to_string()).or_insert_with(|| {
            folder_order.push(folder.to_string());
            Vec::new()
        });
    }

    // Folders first, then loose pages — the usual file-browser convention.
    folder_order.sort();
    let mut nodes: Vec<DocNode> = folder_order
        .iter()
        .map(|folder| {
            let nested = format!("{prefix}{folder}/");
            DocNode {
                id: format!("folder:{nested}"),
                name: folder.clone(),
                page: None,
                children: Some(build(
                    folders.get(folder).map(Vec::as_slice).unwrap_or_default(),
                    pending_folders,
                    &nested,
                )),
            }
        })
        .collect();
    nodes.append(&mut leaves);
    nodes
}
