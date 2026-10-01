//! The private Node runtime (TRD §4.3.6, D13).

use std::{path::PathBuf, time::Duration};

use super::{
    super::error::AcpError,
    archive, fetch,
    resolve::InstallContext,
    store::{read_installed, update_installed, InstalledNode, Layout},
};

/// Private node executable and npm entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeRuntime {
    /// `node` / `node.exe`.
    pub node: PathBuf,
    /// `npm-cli.js`.
    pub npm_cli: PathBuf,
}

/// Paths inside a Node runtime root.
pub fn runtime_at(root: &std::path::Path) -> NodeRuntime {
    if cfg!(windows) {
        NodeRuntime {
            node: root.join("node.exe"),
            npm_cli: root
                .join("node_modules")
                .join("npm")
                .join("bin")
                .join("npm-cli.js"),
        }
    } else {
        NodeRuntime {
            node: root.join("bin").join("node"),
            npm_cli: root
                .join("lib")
                .join("node_modules")
                .join("npm")
                .join("bin")
                .join("npm-cli.js"),
        }
    }
}

/// The installed runtime, if it matches the catalog version.
pub fn installed_runtime(ctx: &InstallContext) -> Option<NodeRuntime> {
    let pin = ctx.catalog.node.as_ref()?;
    let layout = Layout::new(&ctx.root);
    let record = read_installed(&layout).node?;
    if record.version != pin.version {
        return None;
    }
    let runtime = runtime_at(&layout.absolute(&record.path));
    runtime.node.is_file().then_some(runtime)
}

/// Install the pinned Node once; `progress(state, bytes, total)`.
pub async fn ensure_node(
    ctx: &InstallContext,
    progress: &(dyn Fn(&'static str, u64, Option<u64>) + Send + Sync),
) -> Result<NodeRuntime, AcpError> {
    if let Some(runtime) = installed_runtime(ctx) {
        return Ok(runtime);
    }
    let pin =
        ctx.catalog.node.clone().ok_or_else(|| {
            AcpError::UnsupportedPlatform("this build has no Node runtime".into())
        })?;
    let platform = ctx.platform.clone()?;
    let target = pin.targets.get(platform.key).cloned().ok_or_else(|| {
        AcpError::UnsupportedPlatform(format!("no Node runtime for {}", platform.key))
    })?;
    let layout = Layout::new(&ctx.root);
    let suffix = if target.url.ends_with(".zip") { "zip" } else { "tar.gz" };
    let download = layout.tmp().join(format!(
        "node-{}-{}.{suffix}",
        pin.version,
        uuid::Uuid::new_v4().simple()
    ));
    progress("downloading", 0, None);
    fetch::download(&target.url, &target.integrity, &download, &ctx.fetch, &|b, t| {
        progress("downloading", b, t)
    })
    .await?;
    progress("extracting", 0, None);
    let final_dir = layout.node_dir(&pin.version);
    let staging = Layout::staging(&final_dir);
    let extracted = {
        let (download, staging) = (download.clone(), staging.clone());
        tokio::task::spawn_blocking(move || archive::extract(&download, &staging))
            .await
            .map_err(|e| AcpError::Internal(e.to_string()))?
    };
    let _ = std::fs::remove_file(&download);
    if let Err(e) = extracted {
        let _ = std::fs::remove_dir_all(&staging);
        return Err(e);
    }
    let root_rel = target.root.clone().unwrap_or_default();
    let runtime = runtime_at(&staging.join(&root_rel));
    let expected = format!("v{}", pin.version);
    let version = node_version(&runtime.node).await;
    if version.as_deref() != Some(expected.as_str()) {
        let _ = std::fs::remove_dir_all(&staging);
        return Err(AcpError::ValidationFailed(format!(
            "the Node runtime reports {}, expected {expected}",
            version.unwrap_or_else(|| "nothing".into())
        )));
    }
    if final_dir.exists() {
        let _ = std::fs::remove_dir_all(&final_dir);
    }
    std::fs::rename(&staging, &final_dir)?;
    let root = final_dir.join(&root_rel);
    let record = InstalledNode {
        version: pin.version.clone(),
        path: layout.relative(&root),
    };
    update_installed(&layout, |installed| installed.node = Some(record))?;
    Ok(runtime_at(&root))
}

async fn node_version(node: &std::path::Path) -> Option<String> {
    let output = tokio::time::timeout(
        Duration::from_secs(10),
        tokio::process::Command::new(node)
            .arg("--version")
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}
