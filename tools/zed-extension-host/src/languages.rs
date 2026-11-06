//! Common languages bundled by Zed itself, rather than its extension registry.
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};
pub const PROVIDERS: &[(&str, &str, &[&str], &str)] = &[
    ("python", "Python", &["py", "pyi", "pyw"], "pyright"),
    (
        "javascript",
        "JavaScript",
        &["js", "jsx", "mjs", "cjs"],
        "typescript",
    ),
    (
        "typescript",
        "TypeScript",
        &["ts", "mts", "cts"],
        "typescript",
    ),
    ("tsx", "TSX", &["tsx"], "typescript"),
    ("rust", "Rust", &["rs"], "rust-analyzer"),
    ("go", "Go", &["go"], "gopls"),
    ("c", "C", &["c", "h"], "clangd"),
    (
        "cpp",
        "C++",
        &["cpp", "cc", "cxx", "hpp", "hh", "hxx"],
        "clangd",
    ),
    ("css", "CSS", &["css"], "css"),
    ("html", "HTML", &["html", "htm"], "html"),
    ("json", "JSON", &["json"], "json"),
    ("yaml", "YAML", &["yaml", "yml"], "yaml"),
    ("bash", "Shell script", &["sh", "bash"], "bash"),
];
pub fn entries(filter: &str) -> Vec<Value> {
    let needle = filter.to_lowercase();
    PROVIDERS.iter().filter(|(id,name,suffixes,_)|format!("{id} {name} {}",suffixes.join(" ")).to_lowercase().contains(&needle)).map(|(id,name,_,_)|json!({"id":format!("language-{id}"),"installed_id":format!("zircon.language.{id}"),"name":format!("{name} language support"),"version":"1.0.0","description":"Bundled Tree-sitter grammar and language-server provider. Zed includes this language in its core.","provides":["languages","grammars","language-servers"],"metadata_available":true,"source":"zircon"})).collect()
}
pub fn install(id: &str, destination: &Path) -> Result<Value> {
    let (_, name, suffixes, server) = PROVIDERS
        .iter()
        .find(|p| p.0 == id)
        .context("unknown bundled language")?;
    fs::create_dir(destination)?;
    let lid = format!("zircon.language.{id}");
    let output = json!({"schema_version":1,"id":lid,"name":format!("{name} language support"),"version":"1.0.0","description":"Tree-sitter syntax and a configured language server.","contributes":{"languages":[{"id":lid,"name":name,"lsp_id":if id=="tsx"{"typescriptreact"}else{id},"extensions":suffixes,"grammar":{"name":id,"builtin":true,"wasm":"","highlights":""}}],"language_servers":[{"id":format!("{lid}.server"),"languages":[lid],"command":"@zircon-builtin","zed_server":server}]}});
    fs::write(
        destination.join("extension.json"),
        serde_json::to_vec_pretty(&output)?,
    )?;
    Ok(json!({"id":lid}))
}
pub fn grammar(name: &str) -> Result<(tree_sitter::Language, String)> {
    let (language, query) = match name {
        "python" => (
            tree_sitter_python::LANGUAGE,
            tree_sitter_python::HIGHLIGHTS_QUERY.to_owned(),
        ),
        "javascript" => (
            tree_sitter_javascript::LANGUAGE,
            format!(
                "{}\n{}",
                tree_sitter_javascript::HIGHLIGHT_QUERY,
                tree_sitter_javascript::JSX_HIGHLIGHT_QUERY
            ),
        ),
        "typescript" => (
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT,
            format!(
                "{}\n{}",
                tree_sitter_javascript::HIGHLIGHT_QUERY,
                tree_sitter_typescript::HIGHLIGHTS_QUERY
            ),
        ),
        "tsx" => (
            tree_sitter_typescript::LANGUAGE_TSX,
            format!(
                "{}\n{}\n{}",
                tree_sitter_javascript::HIGHLIGHT_QUERY,
                tree_sitter_javascript::JSX_HIGHLIGHT_QUERY,
                tree_sitter_typescript::HIGHLIGHTS_QUERY
            ),
        ),
        "rust" => (
            tree_sitter_rust::LANGUAGE,
            tree_sitter_rust::HIGHLIGHTS_QUERY.to_owned(),
        ),
        "go" => (
            tree_sitter_go::LANGUAGE,
            tree_sitter_go::HIGHLIGHTS_QUERY.to_owned(),
        ),
        "c" => (
            tree_sitter_c::LANGUAGE,
            tree_sitter_c::HIGHLIGHT_QUERY.to_owned(),
        ),
        "cpp" => (
            tree_sitter_cpp::LANGUAGE,
            format!(
                "{}\n{}",
                tree_sitter_c::HIGHLIGHT_QUERY,
                tree_sitter_cpp::HIGHLIGHT_QUERY
            ),
        ),
        "css" => (
            tree_sitter_css::LANGUAGE,
            tree_sitter_css::HIGHLIGHTS_QUERY.to_owned(),
        ),
        "html" => (
            tree_sitter_html::LANGUAGE,
            tree_sitter_html::HIGHLIGHTS_QUERY.to_owned(),
        ),
        "json" => (
            tree_sitter_json::LANGUAGE,
            tree_sitter_json::HIGHLIGHTS_QUERY.to_owned(),
        ),
        "yaml" => (
            tree_sitter_yaml::LANGUAGE,
            tree_sitter_yaml::HIGHLIGHTS_QUERY.to_owned(),
        ),
        "bash" => (
            tree_sitter_bash::LANGUAGE,
            tree_sitter_bash::HIGHLIGHT_QUERY.to_owned(),
        ),
        _ => bail!("unknown bundled grammar {name}"),
    };
    Ok((tree_sitter::Language::new(language), query))
}
fn which(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|p| p.join(name))
            .find(|p| p.is_file())
    })
}
fn npm(work: &Path, packages: &[&str]) -> Result<()> {
    if packages.iter().all(|p| {
        work.join("node_modules")
            .join(p)
            .join("package.json")
            .is_file()
    }) {
        return Ok(());
    }
    let output = crate::process::output(
        Command::new(which("npm").context("Install Node.js and npm to use this language server")?)
            .args([
                "install",
                "--ignore-scripts",
                "--no-audit",
                "--no-fund",
                "--prefix",
            ])
            .arg(work)
            .args(packages),
        std::time::Duration::from_secs(90),
    )?;
    if !output.status.success() {
        bail!(
            "npm language-server installation failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(())
}
pub fn resolve(server: &str, root: &Path, work: &Path, settings: Option<&Path>) -> Result<Value> {
    let settings: Value = settings
        .map(|p| {
            fs::read(p)
                .and_then(|bytes| serde_json::from_slice(&bytes).map_err(std::io::Error::other))
        })
        .transpose()?
        .unwrap_or(json!({}));
    let options = &settings["lsp"][server];
    if let Some(binary) = options["binary"]["path"].as_str() {
        return Ok(
            json!({"command":binary,"args":options["binary"]["arguments"].as_array().cloned().unwrap_or_default(),"cwd":root,"initialization_options":options["initialization_options"],"workspace_configuration":options["settings"]}),
        );
    }
    fs::create_dir_all(work)?;
    let mut args: Vec<String> = Vec::new();
    let command = match server {
        "clangd" => which("clangd")
            .context("Install clangd and place it on PATH for C/C++ language support")?,
        "gopls" => {
            if let Some(p) = which("gopls") {
                p
            } else {
                let output = crate::process::output(
                    Command::new(which("go").context("Install Go to install gopls")?)
                        .args(["install", "golang.org/x/tools/gopls@latest"])
                        .env("GOBIN", work),
                    std::time::Duration::from_secs(90),
                )?;
                if !output.status.success() {
                    bail!(
                        "gopls installation failed: {}",
                        String::from_utf8_lossy(&output.stderr)
                    );
                }
                work.join("gopls")
            }
        }
        "rust-analyzer" => {
            if let Some(p) = which("rust-analyzer") {
                p
            } else {
                let triple = match (std::env::consts::ARCH, std::env::consts::OS) {
                    ("aarch64", "macos") => "aarch64-apple-darwin",
                    ("x86_64", "macos") => "x86_64-apple-darwin",
                    ("aarch64", "linux") => "aarch64-unknown-linux-gnu",
                    ("x86_64", "linux") => "x86_64-unknown-linux-gnu",
                    _ => bail!("install rust-analyzer on PATH for this platform"),
                };
                let p = work.join("rust-analyzer");
                if !p.is_file() {
                    use std::io::Read;
                    let data=crate::catalog::get(&format!("https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-{triple}.gz"),64*1024*1024)?;
                    let mut decoded = Vec::new();
                    flate2::read::GzDecoder::new(data.as_slice())
                        .take(128 * 1024 * 1024 + 1)
                        .read_to_end(&mut decoded)?;
                    if decoded.len() > 128 * 1024 * 1024 {
                        bail!("server binary too large");
                    }
                    fs::write(&p, decoded)?;
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        fs::set_permissions(&p, fs::Permissions::from_mode(0o755))?;
                    }
                }
                p
            }
        }
        "pyright" | "typescript" | "html" | "css" | "json" | "yaml" | "bash" => {
            let (packages, script, flag): (&[&str], &str, &str) = match server {
                "pyright" => (
                    &["pyright"],
                    "pyright/dist/pyright-langserver.js",
                    "--stdio",
                ),
                "typescript" => (
                    &["typescript-language-server", "typescript"],
                    "typescript-language-server/lib/cli.mjs",
                    "--stdio",
                ),
                "html" => (
                    &["vscode-langservers-extracted"],
                    "vscode-langservers-extracted/bin/vscode-html-language-server",
                    "--stdio",
                ),
                "css" => (
                    &["vscode-langservers-extracted"],
                    "vscode-langservers-extracted/bin/vscode-css-language-server",
                    "--stdio",
                ),
                "json" => (
                    &["vscode-langservers-extracted"],
                    "vscode-langservers-extracted/bin/vscode-json-language-server",
                    "--stdio",
                ),
                "yaml" => (
                    &["yaml-language-server"],
                    "yaml-language-server/bin/yaml-language-server",
                    "--stdio",
                ),
                _ => (
                    &["bash-language-server"],
                    "bash-language-server/out/cli.js",
                    "start",
                ),
            };
            npm(work, packages)?;
            args.push(
                work.join("node_modules")
                    .join(script)
                    .to_string_lossy()
                    .into(),
            );
            args.push(flag.into());
            which("node").context("Install Node.js for this language server")?
        }
        _ => bail!("unknown language server provider"),
    };
    Ok(
        json!({"command":command,"args":args,"cwd":root,"initialization_options":options["initialization_options"],"workspace_configuration":options["settings"]}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_bundled_grammar_executes_its_real_highlight_query() {
        for (id, _, _, _) in PROVIDERS {
            let result = crate::highlight::run(
                Path::new("@builtin"),
                id,
                Path::new(""),
                "function main() { return 42; }\n# comment\n{\"name\":\"value\"}\n",
            )
            .unwrap_or_else(|e| panic!("{id}: {e:#}"));
            assert!(result["spans"].is_array(), "{id}");
        }
    }
    #[test]
    fn suffix_search_finds_common_language_providers() {
        for suffix in ["py", "ts", "tsx", "jsx", "rs", "go", "cpp", "yml", "sh"] {
            assert!(!entries(suffix).is_empty(), "{suffix}");
        }
    }
}
