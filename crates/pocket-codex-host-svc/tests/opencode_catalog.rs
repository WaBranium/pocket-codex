//! Runs the OpenCode catalog plugin's boundary tests with Node's built-in
//! test runner. The plugin executes inside OpenCode (Bun), so it is tested as
//! JavaScript; Node 18+ must be on `PATH`.

use std::{path::Path, process::Command};

#[test]
fn opencode_catalog_plugin_boundary() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = Command::new("node")
        .arg("--test")
        .arg(root.join("tests/opencode_catalog.test.mjs"))
        .current_dir(root)
        .output()
        .expect("`node` (18+) is required to test the OpenCode catalog plugin");
    assert!(
        output.status.success(),
        "node --test failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
