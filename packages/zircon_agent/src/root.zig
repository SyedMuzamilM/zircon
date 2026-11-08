//! Agent conversations over native Codex app-server or Agent Client Protocol.
const conversation = @import("conversation.zig");
pub const lines = @import("lines.zig");
pub const transport = @import("transport.zig");
pub const Conversation = conversation.Conversation;
pub const Protocol = conversation.Protocol;
pub const field = conversation.field;
pub const string = conversation.string;

pub const conversation_role = conversation.Role;
pub const Model = conversation.Model;
