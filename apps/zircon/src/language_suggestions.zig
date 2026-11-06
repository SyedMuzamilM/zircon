//! Search terms for files whose language provider has not been installed yet.
//! Installed language associations remain authoritative in the extension registry.
const std = @import("std");
pub fn query(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    inline for (.{
        .{ "Dockerfile", "dockerfile" }, .{ "Containerfile", "dockerfile" }, .{ "Makefile", "make" }, .{ "GNUmakefile", "make" }, .{ "CMakeLists.txt", "cmake" }, .{ "Gemfile", "ruby" }, .{ "Rakefile", "ruby" }, .{ "Podfile", "ruby" }, .{ "mix.exs", "elixir" }, .{ ".bashrc", "bash" }, .{ ".bash_profile", "bash" }, .{ ".zshrc", "bash" }, .{ ".profile", "bash" }, .{ "Justfile", "just" }, .{ "justfile", "just" }, .{ "Cargo.toml", "toml" }, .{ "build.zig.zon", "zig" },
    }) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    const suffix = std.mem.trimStart(u8, std.fs.path.extension(name), ".");
    inline for (.{
        .{ "ex", "elixir" }, .{ "exs", "elixir" }, .{ "heex", "elixir" }, .{ "eex", "elixir" }, .{ "tf", "terraform" }, .{ "tfvars", "terraform" }, .{ "hcl", "terraform" }, .{ "rb", "ruby" }, .{ "erb", "ruby" }, .{ "cs", "csharp" }, .{ "fs", "fsharp" }, .{ "fsx", "fsharp" }, .{ "clj", "clojure" }, .{ "cljs", "clojure" }, .{ "cljc", "clojure" }, .{ "edn", "clojure" }, .{ "erl", "erlang" }, .{ "hrl", "erlang" }, .{ "hs", "haskell" }, .{ "lhs", "haskell" }, .{ "ml", "ocaml" }, .{ "mli", "ocaml" }, .{ "kt", "kotlin" }, .{ "kts", "kotlin" }, .{ "ps1", "powershell" }, .{ "psm1", "powershell" }, .{ "tex", "latex" }, .{ "bib", "latex" }, .{ "pl", "perl" }, .{ "pm", "perl" }, .{ "jl", "julia" }, .{ "f90", "fortran" }, .{ "f95", "fortran" }, .{ "r", "r" }, .{ "rkt", "racket" }, .{ "scm", "scheme" }, .{ "purs", "purescript" }, .{ "v", "verilog" }, .{ "sv", "verilog" }, .{ "svh", "verilog" }, .{ "vhd", "vhdl" }, .{ "vhdl", "vhdl" }, .{ "proto", "proto" }, .{ "gql", "graphql" }, .{ "sh", "bash" }, .{ "zsh", "bash" }, .{ "bash", "bash" }, .{ "py", "python" }, .{ "pyi", "python" }, .{ "js", "javascript" }, .{ "jsx", "javascript" }, .{ "mjs", "javascript" }, .{ "cjs", "javascript" }, .{ "ts", "typescript" }, .{ "tsx", "tsx" }, .{ "mts", "typescript" }, .{ "cts", "typescript" }, .{ "rs", "rust" }, .{ "cc", "cpp" }, .{ "cxx", "cpp" }, .{ "hpp", "cpp" }, .{ "hh", "cpp" }, .{ "hxx", "cpp" }, .{ "yml", "yaml" }, .{ "htm", "html" }, .{ "zon", "zig" },
    }) |entry| if (std.ascii.eqlIgnoreCase(suffix, entry[0])) return entry[1];
    return if (suffix.len > 0) suffix else name;
}
