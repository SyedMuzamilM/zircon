//! Official registry/package adapter. No extension executable runs at install time.
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    path::{Component, Path, PathBuf},
    time::Duration,
};
const REGISTRY: &str =
    "https://raw.githubusercontent.com/zed-industries/extensions/main/extensions.toml";
const API: &str = "https://api.zed.dev";
const MAX_DOWNLOAD: u64 = 64 * 1024 * 1024;
pub fn get(url: &str, limit: u64) -> Result<Vec<u8>> {
    if !url.starts_with("https://") {
        bail!("HTTPS required");
    }
    let response = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(60))
        .build()
        .get(url)
        .call()?;
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        bail!("download exceeds limit");
    }
    Ok(bytes)
}
fn registry() -> Result<toml::Table> {
    Ok(toml::from_str(std::str::from_utf8(&get(
        REGISTRY,
        4 * 1024 * 1024,
    )?)?)?)
}
pub fn list(filter: &str) -> Result<Value> {
    let source = registry()?;
    let mut info = BTreeMap::new();
    // Source registry is authoritative, including entries beyond the API's
    // 1,000-result limit. API metadata only enriches the matching source IDs.
    let query: String = filter
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b == b'-' {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect();
    if let Ok(bytes) = get(
        &format!("{API}/extensions?max_schema_version=1&filter={query}"),
        8 * 1024 * 1024,
    ) {
        if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
            for entry in value["data"].as_array().into_iter().flatten() {
                if let Some(id) = entry["id"].as_str() {
                    info.insert(id.to_owned(), entry.clone());
                }
            }
        }
    }
    let needle = filter.to_lowercase();
    let mut rows = Vec::new();
    for (id, record) in &source {
        let detail = info.get(id);
        let name = detail.and_then(|v| v["name"].as_str()).unwrap_or(id);
        let description = detail.and_then(|v| v["description"].as_str()).unwrap_or("");
        if !format!("{id} {name} {description}")
            .to_lowercase()
            .contains(&needle)
        {
            continue;
        }
        rows.push(json!({"id":id,"name":name,"version":record.get("version").and_then(|v|v.as_str()).unwrap_or(""),"description":description,"provides":detail.map(|v|v["provides"].clone()).unwrap_or(json!([])),"metadata_available":detail.is_some()}));
    }
    let mut builtins = crate::languages::entries(filter);
    builtins.extend(rows);
    Ok(json!({"source":REGISTRY,"total":source.len(),"entries":builtins}))
}
pub fn relative(value: &str) -> Result<PathBuf> {
    let p = Path::new(value);
    if value.contains('\\') || value.contains('\0') || p.is_absolute() {
        bail!("invalid package path");
    }
    let mut normalized = PathBuf::new();
    for c in p.components() {
        match c {
            Component::Normal(s) => normalized.push(s),
            Component::CurDir => (),
            _ => bail!("invalid package path"),
        }
    }
    Ok(normalized)
}
pub fn unpack(bytes: &[u8], destination: &Path) -> Result<()> {
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(bytes));
    let mut total: u64 = 0;
    for (count, entry) in archive.entries()?.enumerate() {
        if count >= 16384 {
            bail!("too many package entries");
        }
        let mut entry = entry?;
        total = total
            .checked_add(entry.size())
            .context("package too large")?;
        if total > 128 * 1024 * 1024 {
            bail!("package exceeds 128 MiB");
        }
        let path = relative(entry.path()?.to_str().context("invalid UTF8 path")?)?;
        let kind = entry.header().entry_type();
        if !kind.is_file() && !kind.is_dir() {
            bail!("package links and special files are unsupported");
        }
        if !path.as_os_str().is_empty() {
            entry.unpack_in(destination)?;
        }
    }
    Ok(())
}
pub fn download(id: &str, destination: &Path) -> Result<Value> {
    let source = registry()?;
    let version = source
        .get(id)
        .and_then(|v| v.get("version"))
        .and_then(|v| v.as_str())
        .context("extension is not in the official registry")?;
    if !id
        .bytes()
        .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c))
        || !version
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-+".contains(&c))
    {
        bail!("invalid registry identity");
    }
    fs::create_dir(destination).context("staging destination must be new")?;
    let outcome = (|| {
        let bytes = get(
            &format!("{API}/extensions/{id}/{version}/download"),
            MAX_DOWNLOAD,
        )?;
        unpack(&bytes, destination)?;
        let manifest: toml::Table =
            toml::from_str(&fs::read_to_string(destination.join("extension.toml"))?)?;
        if manifest.get("id").and_then(|v| v.as_str()) != Some(id)
            || manifest.get("version").and_then(|v| v.as_str()) != Some(version)
        {
            bail!("download identity does not match the official registry");
        }
        convert(destination)
    })();
    if outcome.is_err() {
        let _ = fs::remove_dir_all(destination);
    }
    outcome
}
pub fn import_copy(source: &Path, destination: &Path) -> Result<Value> {
    let source = source.canonicalize()?;
    if destination.starts_with(&source) {
        bail!("staging directory must be outside the source");
    }
    fs::create_dir(destination)?;
    fn copy(
        source: &Path,
        destination: &Path,
        usage: &mut (u64, usize),
        depth: usize,
    ) -> Result<()> {
        if depth > 16 {
            bail!("extension is too deeply nested");
        }
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            let meta = entry.file_type()?;
            usage.1 += 1;
            if usage.1 > 16384 {
                bail!("too many package entries");
            }
            let target = destination.join(entry.file_name());
            if meta.is_symlink() {
                bail!("extension symlinks are unsupported");
            }
            if meta.is_dir() {
                fs::create_dir(&target)?;
                copy(&entry.path(), &target, usage, depth + 1)?;
            } else if meta.is_file() {
                usage.0 += entry.metadata()?.len();
                if usage.0 > 128 * 1024 * 1024 {
                    bail!("extension exceeds 128 MiB");
                }
                fs::copy(entry.path(), target)?;
            } else {
                bail!("unsupported extension file");
            }
        }
        Ok(())
    }
    let result = (|| {
        copy(&source, destination, &mut (0, 0), 0)?;
        convert(destination)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(destination);
    }
    result
}
fn slug(value: &str) -> String {
    let s: String = value
        .to_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let s = s.trim_matches('-');
    if s.is_empty() {
        "unnamed".into()
    } else {
        s.into()
    }
}
fn text<'a>(v: &'a Value, key: &str, fallback: &'a str) -> &'a str {
    v[key].as_str().unwrap_or(fallback)
}
fn color(v: &Value, key: &str, fallback: &str) -> String {
    let s = v[key].as_str().unwrap_or(fallback);
    if s.starts_with('#')
        && (s.len() == 7 || s.len() == 9)
        && s[1..].bytes().all(|b| b.is_ascii_hexdigit())
    {
        s.into()
    } else {
        fallback.into()
    }
}
fn syntax(v: &Value, key: &str, fallback: &str) -> String {
    let s = &v["syntax"][key];
    if s.is_string() {
        color(&json!({"v":s}), "v", fallback)
    } else {
        color(s, "color", fallback)
    }
}
fn paths(
    manifest: &toml::Table,
    key: &str,
    directory: &str,
    suffix: &str,
    root: &Path,
) -> Result<Vec<PathBuf>> {
    if let Some(items) = manifest.get(key).and_then(|v| v.as_array()) {
        if !items.is_empty() {
            return items
                .iter()
                .map(|v| relative(v.as_str().context("invalid contribution path")?))
                .collect();
        }
    }
    let mut result = Vec::new();
    if root.join(directory).is_dir() {
        for item in fs::read_dir(root.join(directory))? {
            let p = item?.path();
            if (suffix.is_empty() && p.is_dir()) || p.extension().is_some_and(|x| x == suffix) {
                result.push(p.strip_prefix(root)?.to_owned());
            }
        }
    }
    result.sort();
    Ok(result)
}
fn read_json(root: &Path, path: &Path) -> Result<Value> {
    Ok(serde_json::from_slice(&fs::read(root.join(path))?)?)
}
fn icon_asset(root: &Path, source: &str, output: &mut BTreeMap<String, String>) -> Result<Value> {
    let path = relative(source)?;
    if let Some(p) = output.get(source) {
        return Ok(json!({"png":p}));
    }
    let bytes = fs::read(root.join(&path))?;
    if bytes.len() > 8 * 1024 * 1024 {
        bail!("icon too large");
    }
    let generated = format!(".zircon-icons/{}.png", output.len());
    let tree = resvg::usvg::Tree::from_data(&bytes, &resvg::usvg::Options::default())?;
    let mut image = resvg::tiny_skia::Pixmap::new(48, 48).context("icon allocation")?;
    let scale = 48.0 / tree.size().width().max(tree.size().height());
    resvg::render(
        &tree,
        resvg::tiny_skia::Transform::from_scale(scale, scale),
        &mut image.as_mut(),
    );
    fs::create_dir_all(root.join(".zircon-icons"))?;
    image.save_png(root.join(&generated))?;
    output.insert(source.into(), generated.clone());
    Ok(json!({"png":generated}))
}
pub fn convert(root: &Path) -> Result<Value> {
    let manifest: toml::Table = toml::from_str(&fs::read_to_string(root.join("extension.toml"))?)?;
    let id = manifest
        .get("id")
        .and_then(|v| v.as_str())
        .context("missing extension id")?;
    let namespace = format!("zed.{}", slug(id));
    let name = manifest.get("name").and_then(|v| v.as_str()).unwrap_or(id);
    let version = manifest
        .get("version")
        .and_then(|v| v.as_str())
        .context("missing version")?;
    let mut themes = Vec::new();
    for path in paths(&manifest, "themes", "themes", "json", root)? {
        for theme in read_json(root, &path)?["themes"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let style = &theme["style"];
            let light = theme["appearance"] == "light";
            let fg = if light { "#383a42" } else { "#abb2bf" };
            let bg = if light { "#fafafa" } else { "#282c34" };
            let selected = style["players"]
                .as_array()
                .and_then(|v| v.first())
                .and_then(|v| v["selection"].as_str())
                .unwrap_or(if light { "#c6d2f5" } else { "#3d5275" });
            let colors = json!({"document":color(style,"editor.background",bg),"chrome":color(style,"title_bar.background",bg),"sidebar":color(style,"panel.background",bg),"panel":color(style,"elevated_surface.background",bg),"line":color(style,"border",if light {"#d5dce6"}else{"#3e4450"}),"text":color(style,"text",fg),"muted":color(style,"text.muted",if light {"#667183"}else{"#7b8495"}),"accent":color(style,"text.accent",if light{"#315f9b"}else{"#74ade8"}),"selected":color(&json!({"s":selected}),"s",selected),"warning":color(style,"warning",if light{"#9d652c"}else{"#d8b579"}),"primary":color(style,"element.selected",if light{"#416fa9"}else{"#4d78a3"})});
            themes.push(json!({"id":format!("{namespace}.theme.{}",slug(text(theme,"name","Theme"))),"name":text(theme,"name","Theme"),"colors":colors,"syntax":{"plain":color(style,"editor.foreground",fg),"keyword":syntax(style,"keyword",if light{"#8a2f94"}else{"#c678dd"}),"string":syntax(style,"string",if light{"#3c7e35"}else{"#98c379"}),"number":syntax(style,"number",if light{"#9c4e00"}else{"#d19a66"}),"comment":syntax(style,"comment",if light{"#68717c"}else{"#7b8495"}),"punctuation":syntax(style,"punctuation",fg),"builtin":syntax(style,"function",if light{"#16647b"}else{"#61afef"})}}));
        }
    }
    let mut icons = Vec::new();
    let mut assets = BTreeMap::new();
    for path in paths(&manifest, "icon_themes", "icon_themes", "json", root)? {
        for theme in read_json(root, &path)?["themes"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let definitions = &theme["file_icons"];
            let mut mappings = |key: &str| -> Result<Vec<Value>> {
                let mut out = Vec::new();
                if let Some(values) = theme[key].as_object() {
                    for (key, value) in values {
                        if let Some(source) = value
                            .as_str()
                            .and_then(|id| definitions[id]["path"].as_str())
                        {
                            out.push(
                                json!({"key":key,"icon":icon_asset(root,source,&mut assets)?}),
                            );
                        }
                    }
                }
                Ok(out)
            };
            let extensions = mappings("file_suffixes")?;
            let stems = mappings("file_stems")?;
            let folder = theme["directory_icons"]["collapsed"]
                .as_str()
                .map(|s| icon_asset(root, s, &mut assets))
                .transpose()?
                .unwrap_or(json!({"symbol":"▸"}));
            let mut folders = Vec::new();
            if let Some(values) = theme["named_directory_icons"].as_object() {
                for (key, value) in values {
                    if let Some(source) = value["collapsed"].as_str() {
                        folders
                            .push(json!({"key":key,"icon":icon_asset(root,source,&mut assets)?}));
                    }
                }
            }
            icons.push(json!({"id":format!("{namespace}.icons.{}",slug(text(theme,"name","Icons"))),"name":text(theme,"name","Icons"),"extensions":extensions,"stems":stems,"folders":folders,"default_folder":folder}));
        }
    }
    let mut languages = Vec::new();
    let mut names = BTreeMap::new();
    for path in paths(&manifest, "languages", "languages", "", root)? {
        let config: toml::Table =
            toml::from_str(&fs::read_to_string(root.join(&path).join("config.toml"))?)?;
        let lname = config
            .get("name")
            .and_then(|v| v.as_str())
            .context("language name")?;
        let lid = format!("{namespace}.language.{}", slug(lname));
        names.insert(lname.to_owned(), lid.clone());
        let mut suffixes = Vec::new();
        let mut filenames = Vec::new();
        for item in config
            .get("path_suffixes")
            .and_then(|v| v.as_array())
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str())
        {
            filenames.push(item);
            suffixes.push(item);
        }
        if suffixes.is_empty() && filenames.is_empty() {
            continue;
        }
        let comment = config
            .get("line_comments")
            .and_then(|v| v.as_array())
            .and_then(|v| v.first())
            .and_then(|v| v.as_str())
            .or_else(|| config.get("line_comment").and_then(|v| v.as_str()))
            .map(str::trim_end);
        let grammar = config
            .get("grammar")
            .and_then(|v| v.as_str())
            .filter(|g| root.join(format!("grammars/{g}.wasm")).is_file());
        let syntax = grammar.filter(|_|root.join(&path).join("highlights.scm").is_file()).map(|g|json!({"name":g,"wasm":format!("grammars/{g}.wasm"),"highlights":path.join("highlights.scm").to_string_lossy()}));
        languages.push(json!({"id":lid,"name":lname,"lsp_id":slug(lname),"extensions":suffixes,"filenames":filenames,"line_comment":comment,"grammar":syntax}));
    }
    let mut servers = Vec::new();
    if let Some(values) = manifest.get("language_servers").and_then(|v| v.as_table()) {
        for (server, entry) in values {
            let mut supported = Vec::new();
            for language in entry
                .get("language")
                .and_then(|v| v.as_str())
                .into_iter()
                .chain(
                    entry
                        .get("languages")
                        .and_then(|v| v.as_array())
                        .into_iter()
                        .flatten()
                        .filter_map(|v| v.as_str()),
                )
            {
                if !names.contains_key(language) {
                    if let Some((provider_id, provider_name, suffixes, _)) =
                        crate::languages::PROVIDERS.iter().find(|(id, name, _, _)| {
                            name.eq_ignore_ascii_case(language) || id.eq_ignore_ascii_case(language)
                        })
                    {
                        let lid = format!("{namespace}.language.{provider_id}");
                        names.insert(language.to_owned(), lid.clone());
                        languages.push(json!({"id":lid,"name":provider_name,"lsp_id":provider_id,"extensions":suffixes,"grammar":{"name":provider_id,"builtin":true,"wasm":"","highlights":""}}));
                    }
                }
                if let Some(lid) = names.get(language) {
                    supported.push(lid.clone());
                    if let Some(id) = entry
                        .get("language_ids")
                        .and_then(|ids| ids.get(language))
                        .and_then(|v| v.as_str())
                    {
                        for definition in &mut languages {
                            if definition["id"] == *lid {
                                definition["lsp_id"] = json!(id);
                            }
                        }
                    }
                }
            }
            supported.sort();
            supported.dedup();
            if !supported.is_empty() {
                servers.push(json!({"id":format!("{namespace}.server.{}",slug(server)),"languages":supported,"command":"@zed-wasm","zed_server":server,"zed_wasm":"extension.wasm"}));
            }
        }
    }
    if themes.is_empty() && icons.is_empty() && languages.is_empty() && servers.is_empty() {
        bail!("This extension provides only capabilities that Zircon does not support yet.");
    }
    let unsupported: Vec<&str> = [
        ("context_servers", "Context servers"),
        ("agent_servers", "AI agents"),
        ("debug_adapters", "Debug adapters"),
        ("debug_locators", "Debugger locators"),
        ("snippets", "Snippets"),
        ("slash_commands", "Slash commands"),
    ]
    .into_iter()
    .filter(|(key, _)| {
        manifest.get(*key).is_some_and(|value| match value {
            toml::Value::Table(v) => !v.is_empty(),
            toml::Value::Array(v) => !v.is_empty(),
            _ => true,
        })
    })
    .map(|(_, label)| label)
    .collect();
    let output = json!({"unsupported_features":unsupported,"schema_version":1,"id":namespace,"name":name,"version":version,"description":manifest.get("description").and_then(|v|v.as_str()).unwrap_or(""),"contributes":{"themes":themes,"icon_themes":icons,"languages":languages,"language_servers":servers}});
    fs::write(
        root.join("extension.json"),
        serde_json::to_vec_pretty(&output)?,
    )?;
    Ok(
        json!({"id":namespace,"version":version,"themes":themes.len(),"icons":icons.len(),"languages":languages.len(),"servers":servers.len()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn packages_cannot_escape_their_managed_directory() {
        for path in [
            "../escape",
            "a/../../escape",
            "/absolute",
            "a\\escape",
            "a\0escape",
        ] {
            assert!(relative(path).is_err(), "{path}");
        }
        assert_eq!(
            relative("./languages/zig/config.toml").unwrap(),
            Path::new("languages/zig/config.toml")
        );
    }
}
