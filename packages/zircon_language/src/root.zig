//! UI-independent stdio language-server client. No server is reported ready
//! until it answers initialize and the initialized notification is enqueued.
const client = @import("client.zig");
pub const framing = @import("framing.zig");
pub const hover = @import("hover.zig");
const model = @import("model.zig");
const synchronization = @import("synchronization.zig");
pub const workspace_edit = @import("workspace_edit.zig");
pub const Client = client.Client;
pub const Config = client.Config;
pub const Wake = client.Wake;
pub const Status = client.Status;
pub const SynchronizationOptions = synchronization.Options;
pub const Position = model.Position;
pub const Range = model.Range;
pub const TextEdit = model.TextEdit;
pub const Location = model.Location;
pub const FileEdits = model.FileEdits;
pub const CodeAction = model.CodeAction;
pub const Diagnostic = model.Diagnostic;
pub const Completion = model.Completion;
pub const Message = model.Message;
pub const deinitMessages = model.deinitMessages;
pub const positionAt = model.positionAt;
pub const offsetAt = model.offsetAt;
pub const fileUri = model.fileUri;

pub const filePath = model.filePath;
