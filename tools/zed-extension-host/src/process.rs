//! Resolver directory ownership and bounded subprocess output for setup hooks.
use anyhow::{bail, Result};
use std::{
    fs::{self, File, OpenOptions},
    io::Read,
    path::Path,
    process::{Command, Output, Stdio},
    time::{Duration, Instant},
};
/// Keep one resolver writing a server's shared install directory. The owned
/// handle releases the cross-process lock on return, failure or process exit.
pub fn lock_work_directory(work: &Path) -> Result<File> {
    fs::create_dir_all(work)?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(work.join(".zircon-resolve.lock"))?;
    lock.lock()?;
    Ok(lock)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolver_installation_has_one_writer_per_directory() -> Result<()> {
        let root = std::env::temp_dir().join(format!(
            "zircon-resolver-lock-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos()
        ));
        let first = lock_work_directory(&root)?;
        let next = OpenOptions::new()
            .read(true)
            .write(true)
            .open(root.join(".zircon-resolve.lock"))?;
        assert!(matches!(
            next.try_lock(),
            Err(std::fs::TryLockError::WouldBlock)
        ));
        let other = lock_work_directory(&root.join("other"))?;
        drop(first);
        next.try_lock()?;
        drop(next);
        drop(other);
        fs::remove_dir_all(root)?;
        Ok(())
    }
}

pub fn output(command: &mut Command, timeout: Duration) -> Result<Output> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let read = |mut stream: Box<dyn Read + Send>| {
        let mut bytes = Vec::new();
        stream
            .by_ref()
            .take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    };
    let out = std::thread::spawn(move || read(Box::new(stdout)));
    let err = std::thread::spawn(move || read(Box::new(stderr)));
    let deadline = Instant::now() + timeout;
    let (status, timed_out) = loop {
        if let Some(status) = child.try_wait()? {
            break (status, false);
        }
        if Instant::now() >= deadline {
            #[cfg(unix)]
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.kill();
            break (child.wait()?, true);
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    // Also close inherited pipes from descendants of a completed hook.
    #[cfg(unix)]
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let stdout = out
        .join()
        .map_err(|_| anyhow::anyhow!("stdout reader failed"))??;
    let stderr = err
        .join()
        .map_err(|_| anyhow::anyhow!("stderr reader failed"))??;
    if timed_out {
        bail!("extension command timed out");
    }
    if stdout.len() > 1024 * 1024 || stderr.len() > 1024 * 1024 {
        bail!("extension command output exceeds 1 MiB");
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}
