//! Agent conversations over native Codex app-server or Agent Client Protocol.
pub const transport = @import("transport.zig");
pub const lines = @import("lines.zig");
pub const Conversation = @import("conversation.zig").Conversation;
pub const Protocol = @import("conversation.zig").Protocol;
pub const field = @import("conversation.zig").field;
pub const string = @import("conversation.zig").string;

pub const conversation_role = @import("conversation.zig").Role;
pub const Model = @import("conversation.zig").Model;
