//! UI-independent stdio language-server client. No server is reported ready
//! until it answers initialize and the initialized notification is enqueued.
pub const Client = @import("client.zig").Client;
pub const Config = @import("client.zig").Config;
pub const Wake = @import("client.zig").Wake;
pub const Status = @import("client.zig").Status;
pub const Position = @import("model.zig").Position;
pub const Range = @import("model.zig").Range;
pub const Diagnostic = @import("model.zig").Diagnostic;
pub const Completion = @import("model.zig").Completion;
pub const Message = @import("model.zig").Message;
pub const deinitMessages = @import("model.zig").deinitMessages;
pub const positionAt = @import("model.zig").positionAt;
pub const offsetAt = @import("model.zig").offsetAt;
pub const fileUri = @import("model.zig").fileUri;
pub const framing = @import("framing.zig");
