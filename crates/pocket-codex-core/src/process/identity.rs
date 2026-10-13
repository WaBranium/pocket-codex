//! Read-only identity checks for external session owners.

use std::path::PathBuf;

use sysinfo::{Pid, ProcessRefreshKind, ProcessStatus, ProcessesToUpdate, System, UpdateKind};

/// A live process identity. Missing fields or an inaccessible process yield no
/// identity rather than an assumption that its session is free.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessIdentity {
    /// Operating-system process id.
    pub pid: u32,
    /// Process creation time in Unix seconds; use only for identity checks.
    pub started: u64,
    /// Resolved executable image, not a mutable process title.
    pub executable: PathBuf,
    /// Resolved current working directory.
    pub cwd: PathBuf,
}

/// Inspect exactly one process without signaling it or reading its environment.
pub fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::new()
            .with_exe(UpdateKind::Always)
            .with_cwd(UpdateKind::Always),
    );
    let process = system.process(Pid::from_u32(pid))?;
    if matches!(process.status(), ProcessStatus::Zombie | ProcessStatus::Dead) {
        return None;
    }
    Some(ProcessIdentity {
        pid,
        started: process.start_time(),
        executable: process.exe()?.canonicalize().ok()?,
        cwd: process.cwd()?.canonicalize().ok()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_identity_is_stable_and_resolves_the_actual_image() {
        let first = process_identity(std::process::id()).expect("own identity");
        assert_eq!(first, process_identity(std::process::id()).expect("same process"));
        assert_eq!(
            first.executable,
            std::env::current_exe()
                .expect("exe")
                .canonicalize()
                .expect("path")
        );
        assert_eq!(
            first.cwd,
            std::env::current_dir()
                .expect("cwd")
                .canonicalize()
                .expect("path")
        );
        assert!(first.started > 0);
    }
}
