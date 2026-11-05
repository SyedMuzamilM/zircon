//! User-facing recovery text for file/edit failures.
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "File not found. Check the path and try again.",
        error.AccessDenied, error.PermissionDenied => "Permission denied. Choose a writable location.",
        error.DiskConflict => "The file changed on disk. Save under a new name to keep both versions.",
        error.PathAlreadyExists => "That path already exists. Choose a new name.",
        error.InvalidUtf8, error.BinaryFile => "This file is not UTF-8 text and cannot be opened.",
        error.FileTooBig, error.FileTooLarge => "This file exceeds the current 64 MiB limit.",
        error.NoDocument => "Open or create a file first.",
        error.InvalidPath => "Enter a valid file path.",
        error.StaleTextSnapshot, error.StaleRevision => "The document changed before that edit. Try the edit again.",
        error.OutOfMemory => "There is not enough memory to complete the operation.",
        error.GitBusy => "A Git operation is running. Wait for it to finish and try again.",
        error.EmptyCommitMessage => "Enter a commit message first.",
        error.InvalidSettings => "This settings value is invalid. The previous value is still active.",
        error.StaleSearchResult => "This search result changed. Run the search again.",
        error.NoLanguageServer => "No enabled language server is configured for this file.",
        error.ServerNotReady => "The language server is starting or unavailable. Try again when it is ready.",
        error.CompletionNotSupported => "This server does not provide completions.",
        error.StaleCompletion, error.StaleDiagnostics => "The document or caret changed. Request fresh language results.",
        error.SnippetNotSupported => "Snippet completions are not supported yet.",
        error.ImageDecodingUnavailable => "Image decoding requires the native macOS app.",
        error.InvalidImage => "This image is invalid, unsupported or exceeds the image limits.",
        error.MarkdownTooLarge => "Markdown preview is limited to 16 MiB.",
        else => @errorName(err),
    };
}
