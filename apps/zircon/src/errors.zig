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
        else => "The operation could not be completed. Check the file path and permissions.",
    };
}
