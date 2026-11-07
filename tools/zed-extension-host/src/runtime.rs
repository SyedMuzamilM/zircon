//! Component-model adapter. The extension runs in an owned worker process.
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use wasmtime::{
    component::{
        types::ComponentItem, Component, Linker, LinkerInstance, Resource, ResourceTable,
        ResourceType, Val,
    },
    Engine, Store,
};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiView};
struct Worktree;
struct State {
    table: ResourceTable,
    wasi: WasiCtx,
    root: PathBuf,
    work: PathBuf,
    settings: Value,
    capabilities: Vec<toml::Value>,
    limits: wasmtime::StoreLimits,
}
impl WasiView for State {
    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }
    fn ctx(&mut self) -> &mut WasiCtx {
        &mut self.wasi
    }
}
fn string(v: &Val) -> Result<&str> {
    if let Val::String(s) = v {
        Ok(s)
    } else {
        bail!("expected string")
    }
}
fn field<'a>(v: &'a Val, name: &str) -> Result<&'a Val> {
    if let Val::Record(fields) = v {
        fields
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v)
            .context("missing record field")
    } else {
        bail!("expected record")
    }
}
fn ok(v: Option<Val>) -> Val {
    Val::Result(Ok(v.map(Box::new)))
}
fn record(fields: Vec<(&str, Val)>) -> Val {
    Val::Record(fields.into_iter().map(|(n, v)| (n.into(), v)).collect())
}
fn which(name: &str) -> Option<PathBuf> {
    if name.contains('/') {
        return None;
    }
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|p| p.join(name))
        .find(|p| p.is_file())
}
fn local(root: &Path, name: &str) -> Result<PathBuf> {
    let input = Path::new(name);
    let relative = if input.is_absolute() {
        input
            .strip_prefix(root)
            .context("path outside extension directory")?
            .to_str()
            .context("non UTF8 path")?
    } else {
        name
    };
    let path = root.join(crate::catalog::relative(relative)?);
    let mut ancestor = Some(path.as_path());
    while let Some(existing) = ancestor {
        if existing.exists() {
            if !existing.canonicalize()?.starts_with(root) {
                bail!("symlink escapes extension directory");
            }
            break;
        }
        ancestor = existing.parent();
    }
    Ok(path)
}
fn github(value: &Value) -> Val {
    record(vec![
        (
            "version",
            Val::String(value["tag_name"].as_str().unwrap_or("").into()),
        ),
        (
            "assets",
            Val::List(
                value["assets"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|a| {
                        record(vec![
                            ("name", Val::String(a["name"].as_str().unwrap_or("").into())),
                            (
                                "download-url",
                                Val::String(
                                    a["browser_download_url"].as_str().unwrap_or("").into(),
                                ),
                            ),
                        ])
                    })
                    .collect(),
            ),
        ),
    ])
}
fn host(state: &mut State, name: &str, args: &[Val]) -> Result<Option<Val>> {
    let result = match name {
        "[method]worktree.id" => Val::U64(1),
        "[method]worktree.root-path" => Val::String(state.root.to_string_lossy().into()),
        "[method]worktree.which" => Val::Option(
            which(string(&args[1])?).map(|p| Box::new(Val::String(p.to_string_lossy().into()))),
        ),
        "[method]worktree.shell-env" => Val::List(
            ["PATH", "HOME", "LANG", "SHELL", "NVM_BIN", "ZIG_EXE"]
                .into_iter()
                .filter_map(|k| {
                    std::env::var(k)
                        .ok()
                        .map(|v| Val::Tuple(vec![Val::String(k.into()), Val::String(v)]))
                })
                .collect(),
        ),
        "[method]worktree.read-text-file" => {
            let path = local(&state.root, string(&args[1])?)?.canonicalize()?;
            if !path.starts_with(&state.root) || fs::metadata(&path)?.len() > 4 * 1024 * 1024 {
                bail!("file outside worktree or too large");
            }
            ok(Some(Val::String(fs::read_to_string(path)?)))
        }
        "get-settings" => {
            let category = string(&args[1])?;
            let mut settings = state.settings.get(category).cloned().unwrap_or(json!({}));
            if let Val::Option(Some(key)) = &args[2] {
                settings = settings.get(string(key)?).cloned().unwrap_or(json!({}));
            }
            ok(Some(Val::String(settings.to_string())))
        }
        "set-language-server-installation-status" => return Ok(None),
        "current-platform" => Val::Tuple(vec![
            Val::Enum(
                if cfg!(target_os = "macos") {
                    "mac"
                } else if cfg!(target_os = "windows") {
                    "windows"
                } else {
                    "linux"
                }
                .into(),
            ),
            Val::Enum(
                if cfg!(target_arch = "aarch64") {
                    "aarch64"
                } else if cfg!(target_arch = "x86") {
                    "x86"
                } else {
                    "x8664"
                }
                .into(),
            ),
        ]),
        "latest-github-release" | "github-release-by-tag-name" => {
            let repo = string(&args[0])?;
            if repo.split('/').count() != 2
                || !repo
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_./".contains(&b))
            {
                bail!("invalid repository");
            }
            let endpoint = if name == "latest-github-release" {
                "latest".into()
            } else {
                format!("tags/{}", string(&args[1])?)
            };
            let data: Value = serde_json::from_slice(&crate::catalog::get(
                &format!("https://api.github.com/repos/{repo}/releases/{endpoint}"),
                8 * 1024 * 1024,
            )?)?;
            ok(Some(github(&data)))
        }
        "download-file" => {
            let data = crate::catalog::get(string(&args[0])?, 128 * 1024 * 1024)?;
            let dest = local(&state.work, string(&args[1])?)?;
            let kind = if let Val::Enum(s) = &args[2] {
                s.as_str()
            } else {
                ""
            };
            fs::create_dir_all(dest.parent().context("download parent")?)?;
            match kind {
                "uncompressed" => fs::write(&dest, data)?,
                "gzip" => {
                    use std::io::Read;
                    let mut out = Vec::new();
                    flate2::read::GzDecoder::new(data.as_slice())
                        .take(128 * 1024 * 1024 + 1)
                        .read_to_end(&mut out)?;
                    if out.len() > 128 * 1024 * 1024 {
                        bail!("expanded file too large");
                    }
                    fs::write(&dest, out)?;
                }
                "gzip-tar" => {
                    fs::create_dir_all(&dest)?;
                    crate::catalog::unpack(&data, &dest)?;
                }
                "zip" => {
                    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(data))?;
                    let mut total = 0;
                    for i in 0..archive.len() {
                        let mut entry = archive.by_index(i)?;
                        total += entry.size();
                        if i > 16384 || total > 128 * 1024 * 1024 {
                            bail!("archive too large");
                        }
                        let name = entry.name();
                        let path = local(&dest, name)?;
                        if entry.unix_mode().is_some_and(|m| m & 0o170000 == 0o120000) {
                            bail!("archive links unsupported");
                        }
                        if entry.is_dir() {
                            fs::create_dir_all(path)?;
                        } else {
                            fs::create_dir_all(path.parent().context("archive path")?)?;
                            let mut f = fs::File::create(path)?;
                            std::io::copy(&mut entry, &mut f)?;
                        }
                    }
                }
                _ => bail!("unsupported download format {kind}"),
            }
            ok(None)
        }
        "make-file-executable" => {
            let path = local(&state.work, string(&args[0])?)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
            }
            ok(None)
        }
        "node-binary-path" => ok(Some(Val::String(
            which("node")
                .context("Node.js is required by this language server")?
                .to_string_lossy()
                .into(),
        ))),
        "npm-package-latest-version" => {
            let package = string(&args[0])?;
            let data: Value = serde_json::from_slice(&crate::catalog::get(
                &format!("https://registry.npmjs.org/{package}/latest"),
                4 * 1024 * 1024,
            )?)?;
            ok(Some(Val::String(
                data["version"].as_str().context("npm version")?.into(),
            )))
        }
        "npm-package-installed-version" => {
            let package = string(&args[0])?;
            let path = local(&state.work, &format!("node_modules/{package}/package.json"))?;
            let version = fs::read(path)
                .ok()
                .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
                .and_then(|v| v["version"].as_str().map(str::to_owned));
            ok(Some(Val::Option(version.map(|v| Box::new(Val::String(v))))))
        }
        "npm-install-package" => {
            let package = string(&args[0])?;
            let version = string(&args[1])?;
            if package.starts_with('-')
                || version.starts_with('-')
                || package.contains(':')
                || package.contains("..")
            {
                bail!("invalid npm package");
            }
            let output = crate::process::output(
                Command::new(which("npm").context("npm is required by this language server")?)
                    .args([
                        "install",
                        "--ignore-scripts",
                        "--no-audit",
                        "--no-fund",
                        "--prefix",
                    ])
                    .arg(&state.work)
                    .arg(format!("{package}@{version}")),
                std::time::Duration::from_secs(90),
            )?;
            if !output.status.success() {
                bail!(
                    "npm installation failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
            }
            ok(None)
        }
        "fetch" => {
            use std::io::Read;
            let request = &args[0];
            let url = string(field(request, "url")?)?;
            if !url.starts_with("https://") {
                bail!("HTTPS required");
            }
            let method = if let Val::Enum(method) = field(request, "method")? {
                method.to_uppercase()
            } else {
                bail!("invalid HTTP method")
            };
            let redirects = match field(request, "redirect-policy")? {
                Val::Variant(name, _) if name == "no-follow" => 0,
                Val::Variant(name, Some(value)) if name == "follow-limit" => {
                    if let Val::U32(n) = value.as_ref() {
                        (*n).min(10)
                    } else {
                        0
                    }
                }
                _ => 10,
            };
            let agent = ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(60))
                .redirects(redirects)
                .build();
            let mut http = agent.request(&method, url);
            if let Val::List(headers) = field(request, "headers")? {
                for header in headers {
                    if let Val::Tuple(pair) = header {
                        http = http.set(string(&pair[0])?, string(&pair[1])?);
                    }
                }
            }
            let body = if let Val::Option(Some(value)) = field(request, "body")? {
                if let Val::List(bytes) = value.as_ref() {
                    bytes
                        .iter()
                        .map(|v| {
                            if let Val::U8(b) = v {
                                Ok(*b)
                            } else {
                                bail!("invalid body byte")
                            }
                        })
                        .collect::<Result<Vec<_>>>()?
                } else {
                    bail!("invalid HTTP body")
                }
            } else {
                Vec::new()
            };
            let response = match http.send_bytes(&body) {
                Ok(value) => value,
                Err(ureq::Error::Status(_, response)) => response,
                Err(error) => return Err(error.into()),
            };
            let headers = response
                .headers_names()
                .iter()
                .flat_map(|name| {
                    response.all(name).into_iter().map(|value| {
                        Val::Tuple(vec![Val::String(name.clone()), Val::String(value.into())])
                    })
                })
                .collect();
            let mut bytes = Vec::new();
            response
                .into_reader()
                .take(16 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)?;
            if bytes.len() > 16 * 1024 * 1024 {
                bail!("HTTP response too large");
            }
            ok(Some(record(vec![
                ("headers", Val::List(headers)),
                ("body", Val::List(bytes.into_iter().map(Val::U8).collect())),
            ])))
        }
        "run-command" => {
            let command = string(field(&args[0], "command")?)?;
            let arguments = if let Val::List(items) = field(&args[0], "args")? {
                items
                    .iter()
                    .map(|v| Ok(string(v)?.to_owned()))
                    .collect::<Result<Vec<_>>>()?
            } else {
                bail!("invalid command arguments")
            };
            let allowed = state.capabilities.iter().any(|capability| {
                if capability.get("kind").and_then(|v| v.as_str()) != Some("process:exec") {
                    return false;
                }
                let binary = capability
                    .get("command")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if binary != command && binary != "*" {
                    return false;
                }
                let Some(pattern) = capability.get("args").and_then(|v| v.as_array()) else {
                    return false;
                };
                for (i, part) in pattern.iter().enumerate() {
                    let part = part.as_str().unwrap_or("");
                    if part == "**" {
                        return true;
                    }
                    if arguments
                        .get(i)
                        .is_none_or(|arg| part != "*" && part != arg)
                    {
                        return false;
                    }
                }
                pattern.len() == arguments.len()
            });
            if !allowed {
                bail!("process:exec capability is missing for {command}");
            }
            let mut process = Command::new(command);
            process.args(arguments).current_dir(&state.work);
            if let Val::List(env) = field(&args[0], "env")? {
                for entry in env {
                    if let Val::Tuple(pair) = entry {
                        process.env(string(&pair[0])?, string(&pair[1])?);
                    }
                }
            }
            let result = crate::process::output(&mut process, std::time::Duration::from_secs(15))?;
            ok(Some(record(vec![
                (
                    "status",
                    Val::Option(result.status.code().map(|v| Box::new(Val::S32(v)))),
                ),
                (
                    "stdout",
                    Val::List(result.stdout.into_iter().map(Val::U8).collect()),
                ),
                (
                    "stderr",
                    Val::List(result.stderr.into_iter().map(Val::U8).collect()),
                ),
            ])))
        }
        _ => bail!("unsupported Zed extension API: {name}"),
    };
    Ok(Some(result))
}
fn define(
    linker: &mut LinkerInstance<State>,
    name: &str,
    item: ComponentItem,
    engine: &Engine,
) -> Result<()> {
    match item {
        ComponentItem::ComponentInstance(instance) => {
            let mut nested = linker.instance(name)?;
            for (n, item) in instance.exports(engine) {
                define(&mut nested, n, item, engine)?;
            }
        }
        ComponentItem::Resource(_) => {
            linker.resource(name, ResourceType::host::<Worktree>(), |_, _| Ok(()))?;
        }
        ComponentItem::ComponentFunc(_) => {
            let name = name.to_owned();
            linker.func_new(&name.clone(), move |mut cx, args, results| {
                let output = host(cx.data_mut(), &name, args);
                for arg in args {
                    if let Val::Resource(resource) = arg {
                        resource.resource_drop(&mut cx)?;
                    }
                }
                match output {
                    Ok(Some(value)) => {
                        if !results.is_empty() {
                            results[0] = value;
                        }
                    }
                    Ok(None) => (),
                    Err(error) => {
                        if results.len() == 1 {
                            results[0] =
                                Val::Result(Err(Some(Box::new(Val::String(format!("{error:#}"))))));
                        } else {
                            return Err(error);
                        }
                    }
                };
                Ok(())
            })?;
        }
        _ => (),
    }
    Ok(())
}
pub fn resolve(
    wasm: &Path,
    server: &str,
    root: &Path,
    work: &Path,
    settings: Option<&Path>,
) -> Result<Value> {
    let _work_lock = crate::process::lock_work_directory(work)?;
    let root = root.canonicalize()?;
    let work = work.canonicalize()?;
    let mut config = wasmtime::Config::new();
    config.max_wasm_stack(2 * 1024 * 1024);
    config.consume_fuel(true);
    config.wasm_component_model(true);
    let engine = Engine::new(&config)?;
    let component = Component::from_file(&engine, wasm)?;
    let mut wasi = WasiCtxBuilder::new();
    wasi.env("PWD", work.to_string_lossy()).inherit_stderr();
    wasi.preopened_dir(
        &work,
        work.to_string_lossy(),
        wasmtime_wasi::DirPerms::all(),
        wasmtime_wasi::FilePerms::all(),
    )?;
    wasi.preopened_dir(
        &work,
        ".",
        wasmtime_wasi::DirPerms::all(),
        wasmtime_wasi::FilePerms::all(),
    )?;
    let mut store = Store::new(
        &engine,
        State {
            limits: wasmtime::StoreLimitsBuilder::new()
                .memory_size(256 * 1024 * 1024)
                .instances(64)
                .build(),
            table: ResourceTable::new(),
            wasi: wasi.build(),
            capabilities: fs::read_to_string(
                wasm.parent()
                    .context("extension directory")?
                    .join("extension.toml"),
            )
            .ok()
            .and_then(|s| toml::from_str::<toml::Table>(&s).ok())
            .and_then(|v| v.get("capabilities").and_then(|v| v.as_array()).cloned())
            .unwrap_or_default(),
            root,
            work: work.clone(),
            settings: settings
                .map(|p| {
                    fs::read(p)
                        .and_then(|b| serde_json::from_slice(&b).map_err(std::io::Error::other))
                })
                .transpose()?
                .unwrap_or(json!({})),
        },
    );
    store.limiter(|state| &mut state.limits);
    store.set_fuel(1_000_000_000)?;
    let mut linker = Linker::new(&engine);
    wasmtime_wasi::add_to_linker_sync(&mut linker)?;
    for (name, item) in component.component_type().imports(&engine) {
        if !name.starts_with("wasi:") {
            define(&mut linker.root(), name, item, &engine)?;
        }
    }
    let instance = linker.instantiate(&mut store, &component)?;
    let init = instance
        .get_func(&mut store, "init-extension")
        .context("missing init-extension")?;
    init.call(&mut store, &[], &mut [])?;
    init.post_return(&mut store)?;
    let func = instance
        .get_func(&mut store, "language-server-command")
        .context("missing language-server-command")?;
    let resource = Resource::<Worktree>::new_own(1).try_into_resource_any(&mut store)?;
    let mut out = [Val::Bool(false)];
    func.call(
        &mut store,
        &[Val::String(server.into()), Val::Resource(resource)],
        &mut out,
    )?;
    let command = match &out[0] {
        Val::Result(Ok(Some(command))) => command.as_ref(),
        Val::Result(Err(Some(error))) => bail!("{}", string(error)?),
        _ => bail!("invalid language server command"),
    };
    let mut executable = PathBuf::from(string(field(command, "command")?)?);
    if executable.is_relative() && executable.components().count() > 1 {
        executable = work.join(executable);
    }
    let args = if let Val::List(items) = field(command, "args")? {
        items
            .iter()
            .map(|v| Ok(string(v)?.to_owned()))
            .collect::<Result<Vec<_>>>()?
    } else {
        bail!("invalid command args")
    };
    let env = if let Val::List(items) = field(command, "env")? {
        items
            .iter()
            .map(|v| {
                if let Val::Tuple(pair) = v {
                    Ok((string(&pair[0])?.to_owned(), string(&pair[1])?.to_owned()))
                } else {
                    bail!("invalid environment")
                }
            })
            .collect::<Result<Vec<_>>>()?
    } else {
        Vec::new()
    };
    let mut result = json!({"command":executable,"args":args,"env":env,"cwd":work});
    func.post_return(&mut store)?;
    for (export, key) in [
        (
            "language-server-initialization-options",
            "initialization_options",
        ),
        (
            "language-server-workspace-configuration",
            "workspace_configuration",
        ),
    ] {
        if let Some(function) = instance.get_func(&mut store, export) {
            let mut output = [Val::Bool(false)];
            function.call(
                &mut store,
                &[Val::String(server.into()), Val::Resource(resource)],
                &mut output,
            )?;
            match &output[0] {
                Val::Result(Ok(Some(value))) => {
                    if let Val::Option(Some(value)) = value.as_ref() {
                        result[key] = serde_json::from_str(string(value)?)?;
                    }
                }
                Val::Result(Err(Some(error))) => bail!("{}", string(error)?),
                _ => (),
            }
            function.post_return(&mut store)?;
        }
    }
    resource.resource_drop(&mut store)?;
    Ok(result)
}
