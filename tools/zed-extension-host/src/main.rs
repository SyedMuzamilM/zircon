mod catalog;
mod highlight;
mod languages;
mod process;
mod runtime;
use anyhow::{Context, Result};
use serde_json::Value;
use std::{
    io::{self, Read},
    path::Path,
};
fn run() -> Result<Value> {
    let args: Vec<String> = std::env::args().collect();
    let arg = |n: usize| args.get(n).map(String::as_str).context("missing argument");
    match arg(1)? {
        "catalog" => catalog::list(args.get(2).map(String::as_str).unwrap_or("")),
        "install" => {
            if let Some(id) = arg(2)?.strip_prefix("language-") {
                languages::install(id, Path::new(arg(3)?))
            } else {
                catalog::download(arg(2)?, Path::new(arg(3)?))
            }
        }
        "resolve-builtin" => languages::resolve(
            arg(2)?,
            Path::new(arg(3)?),
            Path::new(arg(4)?),
            args.get(5).filter(|s| !s.is_empty()).map(Path::new),
        ),
        "import-copy" => catalog::import_copy(Path::new(arg(2)?), Path::new(arg(3)?)),
        "import" => catalog::convert(Path::new(arg(2)?)),
        "resolve" => runtime::resolve(
            Path::new(arg(2)?),
            arg(3)?,
            Path::new(arg(4)?),
            Path::new(arg(5)?),
            args.get(6).filter(|s| !s.is_empty()).map(Path::new),
        ),
        "highlight" => {
            let mut source = String::new();
            io::stdin()
                .take(8 * 1024 * 1024 + 1)
                .read_to_string(&mut source)?;
            if source.len() > 8 * 1024 * 1024 {
                anyhow::bail!("source exceeds 8 MiB");
            }
            highlight::run(Path::new(arg(2)?), arg(3)?, Path::new(arg(4)?), &source)
        }
        _ => anyhow::bail!("expected catalog, install, import, resolve or highlight"),
    }
}
fn main() {
    match run() {
        Ok(value) => println!("{value}"),
        Err(error) => {
            eprintln!("{error:#}");
            std::process::exit(1);
        }
    }
}
