const std = @import("std");
const Allocator = std.mem.Allocator;
const StringPool = @import("pool.zig").StringPool;

pub const Position = extern struct {
    line: u32,
    char: u32,
};

pub const Text = extern struct {
    content_id: u32,
    start: Position,
    end: Position,
};

pub const ProcInst = extern struct {
    target_id: u32,
    content_id: u32,
    start: Position,
    end: Position,
};

pub const Attr = extern struct {
    name_id: u32,
    value_id: u32,
};

pub const Tag = extern struct {
    name_id: u32,
    attributes: [*c]const Attr,
    attributes_len: usize,
    start: Position,
    end: Position,
};

pub const EntityType = enum(c_int) {
    open_tag,
    close_tag,
    text,
    comment,
    processing_instruction,
    cdata,
};

pub const Entity = extern struct {
    tag: EntityType,
    data: extern union {
        open_tag: Tag,
        close_tag: Tag,
        text: Text,
        comment: Text,
        processing_instruction: Text,
        cdata: Text,
    },
};

const State = enum {
    Text,
    IgnoreComment,
    IgnoreInstruction,
    TagName,
    Tag,
    AttrName,
    AttrEq,
    AttrQuot,
    AttrValue,
    Cdata,
    IgnoreCdata,
};

pub const ParseError = error{
    UnexpectedEndOfInput,
    InvalidCharacter,
    UnterminatedString,
    MalformedEntity,
    AttributeLimitExceeded,
    OutOfMemory,
};

pub const SaxParser = struct {
    allocator: Allocator,
    pool: *StringPool,
    on_event: ?*const fn (?*anyopaque, Entity) callconv(.C) void,
    attributes: std.ArrayList(Attr),
    context: ?*anyopaque,

    pos: usize = 0,
    state: State = .Text,
    end_tag: bool = false,
    self_closing: bool = false,
    tag_start_byte: usize = 0,
    tag_name_id: u32 = 0,
    attr_name_id: u32 = 0,
    buffer: []const u8 = &.{},

    pub fn init(allocator: Allocator, pool: *StringPool, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, Entity) callconv(.C) void) !SaxParser {
        return SaxParser{
            .allocator = allocator,
            .pool = pool,
            .attributes = std.ArrayList(Attr).init(allocator),
            .context = context,
            .on_event = callback,
        };
    }

    pub fn deinit(self: *SaxParser) void {
        self.attributes.deinit();
    }

    pub fn write(self: *SaxParser, input: []const u8) ParseError!void {
        self.buffer = input;
        self.pos = 0;
        var record_start: usize = 0;
        var quote_char: ?u8 = null;

        while (self.pos < self.buffer.len) : (self.pos += 1) {
            const c = self.buffer[self.pos];

            switch (self.state) {
                .Text => {
                    if (c == '<') {
                        // Emit any accumulated text
                        if (self.pos > record_start) {
                            try self.emitText(.text, record_start, self.pos);
                        }

                        self.tag_start_byte = self.pos;
                        self.end_tag = false;
                        self.self_closing = false;
                        self.attributes.clearRetainingCapacity();
                        self.state = self.detectSpecialConstruct();
                        record_start = self.pos + 1;

                        // Skip the increment if we detected a special construct that moved pos
                        if (self.state == .IgnoreComment or self.state == .Cdata or self.state == .IgnoreInstruction) {
                            record_start = self.pos + 1;
                            continue;
                        }

                        // For end tags, we already moved past the '/'
                        if (self.end_tag) {
                            record_start = self.pos + 1;
                        }
                    }
                },
                .IgnoreComment => {
                    if (try self.tryCompleteComment(record_start)) {
                        record_start = self.pos + 1;
                    }
                },
                .IgnoreInstruction => {
                    if (try self.tryCompleteProcessingInstruction(record_start)) {
                        record_start = self.pos + 1;
                    }
                },
                .Cdata => {
                    if (try self.tryCompleteCdata(record_start)) {
                        record_start = self.pos + 1;
                    }
                },
                .TagName => {
                    if (isWhitespace(c)) {
                        const temp_name = self.buffer[record_start..self.pos];
                        self.tag_name_id = try self.pool.intern(temp_name);
                        self.state = .Tag;
                        record_start = self.pos + 1;
                    } else if (c == '/') {
                        if (self.pos + 1 < self.buffer.len and self.buffer[self.pos + 1] == '>') {
                            const temp_name = self.buffer[record_start..self.pos];
                            self.tag_name_id = try self.pool.intern(temp_name);
                            self.self_closing = true;
                            self.pos += 1; // Skip '>'
                            try self.completeTag();
                            self.state = .Text;
                            record_start = self.pos + 1;
                        }
                    } else if (c == '>') {
                        const temp_name = self.buffer[record_start..self.pos];
                        self.tag_name_id = try self.pool.intern(temp_name);
                        try self.completeTag();
                        self.state = .Text;
                        record_start = self.pos + 1;
                    }
                },
                .Tag => {
                    if (c == '>') {
                        try self.completeTag();
                        self.state = .Text;
                        record_start = self.pos + 1;
                    } else if (c == '/') {
                        if (self.pos + 1 < self.buffer.len and self.buffer[self.pos + 1] == '>') {
                            self.self_closing = true;
                            self.pos += 1; // Skip '>'
                            try self.completeTag();
                            self.state = .Text;
                            record_start = self.pos + 1;
                        }
                    } else if (!isWhitespace(c)) {
                        self.state = .AttrName;
                        record_start = self.pos;
                    }
                },
                .AttrName => {
                    if (c == '=') {
                        const temp_name = self.buffer[record_start..self.pos];
                        if (temp_name.len == 0 or std.mem.eql(u8, temp_name, "/")) {
                            self.state = .AttrEq;
                            record_start = self.pos + 1;
                            continue;
                        }
                        const name_id = try self.pool.intern(temp_name);
                        self.attr_name_id = name_id;
                        self.state = .AttrEq;
                        record_start = self.pos + 1;
                    } else if (isWhitespace(c) or c == '>' or c == '/') {
                        const temp_name = self.buffer[record_start..self.pos];
                        if (temp_name.len > 0 and !std.mem.eql(u8, temp_name, "/")) {
                            const name_id = try self.pool.intern(temp_name);
                            const value_id = try self.pool.intern("");
                            try self.addAttribute(name_id, value_id);
                        }
                        self.state = .Tag;
                        record_start = self.pos + 1;
                        if (c == '>' or c == '/') {
                            self.pos -= 1; // Reprocess in Tag state
                        }
                    }
                },
                .AttrEq => {
                    if (c == '"' or c == '\'') {
                        quote_char = c;
                        self.state = .AttrQuot;
                        record_start = self.pos + 1;
                    } else if (!isWhitespace(c)) {
                        self.state = .AttrValue;
                        record_start = self.pos;
                        self.pos -= 1; // Reprocess this char in AttrValue
                    }
                },
                .AttrQuot => {
                    if (c == quote_char orelse unreachable) {
                        const temp_value = self.buffer[record_start..self.pos];
                        const value_id = try self.pool.intern(temp_value);
                        try self.addAttribute(self.attr_name_id, value_id);
                        self.state = .Tag;
                        record_start = self.pos + 1;
                        quote_char = null;
                    }
                },
                .AttrValue => {
                    if (isWhitespace(c) or c == '>' or c == '/') {
                        const temp_value = self.buffer[record_start..self.pos];
                        const value_id = try self.pool.intern(temp_value);
                        try self.addAttribute(self.attr_name_id, value_id);
                        self.state = .Tag;
                        record_start = self.pos + 1;
                        if (c == '>' or c == '/') {
                            self.pos -= 1; // Reprocess in Tag state
                        }
                    }
                },
                .IgnoreCdata => {
                    // Not used in current implementation
                },
            }
        }

        // Emit any remaining text at the end
        if (self.state == .Text and record_start < self.buffer.len) {
            try self.emitText(.text, record_start, self.buffer.len);
        }
    }

    fn get_position(self: *SaxParser, byte_pos: usize) Position {
        var line: u32 = 1;
        var char: u32 = 1;
        var pos: usize = 0;
        while (pos < byte_pos and pos < self.buffer.len) {
            const byte = self.buffer[pos];
            if (byte < 0x80 or byte >= 0xC0) {
                if (byte == '\n') {
                    line += 1;
                    char = 1;
                } else {
                    char += 1;
                }
            }
            pos += 1;
        }
        return Position{ .line = line, .char = char };
    }

    fn emitOpenTag(self: *SaxParser) ParseError!void {
        const open_tag = Tag{
            .name_id = self.tag_name_id,
            .attributes = if (self.attributes.items.len > 0) self.attributes.items.ptr else null,
            .attributes_len = self.attributes.items.len,
            .start = self.get_position(self.tag_start_byte),
            .end = self.get_position(self.pos),
        };

        const entity = Entity{ .tag = .open_tag, .data = .{ .open_tag = open_tag } };
        if (self.on_event) |callback| {
            callback(self.context, entity);
        }

        self.attributes.clearRetainingCapacity();
    }

    fn emitCloseTag(self: *SaxParser) ParseError!void {
        const close_tag = Tag{
            .name_id = self.tag_name_id,
            .attributes = null,
            .attributes_len = 0,
            .start = self.get_position(self.tag_start_byte),
            .end = self.get_position(self.pos),
        };

        const entity = Entity{ .tag = .close_tag, .data = .{ .close_tag = close_tag } };
        if (self.on_event) |callback| {
            callback(self.context, entity);
        }
    }

    fn emitText(self: *SaxParser, entity_type: EntityType, start_pos: usize, end_pos: usize) ParseError!void {
        if (end_pos <= start_pos) return;

        const slice = self.buffer[start_pos..end_pos];
        const id = try self.pool.intern(slice);
        const text = Text{
            .content_id = id,
            .start = self.get_position(start_pos),
            .end = self.get_position(end_pos - 1),
        };

        const entity = Entity{
            .tag = entity_type,
            .data = .{ .text = text },
        };

        if (self.on_event) |callback| {
            callback(self.context, entity);
        }
    }

    fn completeTag(self: *SaxParser) ParseError!void {
        if (self.end_tag) {
            try self.emitCloseTag();
        } else {
            try self.emitOpenTag();

            // For self-closing tags, immediately emit a close tag too
            if (self.self_closing) {
                try self.emitCloseTag();
            }
        }

        return;
    }

    fn addAttribute(self: *SaxParser, name_id: u32, value_id: u32) ParseError!void {
        self.attributes.append(.{ .name_id = name_id, .value_id = value_id }) catch return ParseError.AttributeLimitExceeded;
    }

    fn tryCompleteComment(self: *SaxParser, record_start: usize) ParseError!bool {
        if (self.pos + 2 >= self.buffer.len) return false;

        if (std.mem.eql(u8, self.buffer[self.pos..self.pos + 3], "-->")) {
            try self.emitText(.comment, record_start, self.pos);
            self.pos += 2; // Skip the remaining "-->"
            self.state = .Text;
            return true;
        }
        return false;
    }

    fn tryCompleteProcessingInstruction(self: *SaxParser, record_start: usize) ParseError!bool {
        if (self.pos + 1 >= self.buffer.len) return false;

        if (std.mem.eql(u8, self.buffer[self.pos..self.pos + 2], "?>")) {
            try self.emitText(.processing_instruction, record_start, self.pos);
            self.pos += 1; // Skip the remaining "?>"
            self.state = .Text;
            return true;
        }
        return false;
    }

    fn tryCompleteCdata(self: *SaxParser, record_start: usize) ParseError!bool {
        if (self.pos + 2 >= self.buffer.len) return false;

        if (std.mem.eql(u8, self.buffer[self.pos .. self.pos + 3], "]]>")) {
            try self.emitText(.cdata, record_start, self.pos);
            self.pos += 2; // Skip the remaining "]]>"
            self.state = .Text;
            return true;
        }
        return false;
    }

    inline fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn detectSpecialConstruct(self: *SaxParser) State {
        // Check for comments: <!--
        if (self.pos + 3 < self.buffer.len and
            std.mem.eql(u8, self.buffer[self.pos + 1..self.pos + 4], "!--")) {
            self.pos += 3; // Skip "!--"
            return .IgnoreComment;
        }

        // Check for CDATA: <![CDATA[
        if (self.pos + 8 < self.buffer.len and
            std.mem.eql(u8, self.buffer[self.pos + 1..self.pos + 9], "![CDATA[")) {
            self.pos += 8; // Skip "![CDATA["
            return .Cdata;
        }

        // Check for processing instructions: <?
        if (self.pos + 1 < self.buffer.len and self.buffer[self.pos + 1] == '?') {
            self.pos += 1; // Skip "?"
            return .IgnoreInstruction;
        }

        // Check for closing tag: </
        if (self.pos + 1 < self.buffer.len and self.buffer[self.pos + 1] == '/') {
            self.end_tag = true;
            self.pos += 1; // Skip "/"
            return .TagName;
        }

        // Regular opening tag: <tagname
        return .TagName;
    }
};

pub export fn create_parser(allocator: *Allocator, pool: *StringPool, context: ?*anyopaque, callback: ?*const fn (?*anyopaque, Entity) callconv(.C) void) ?*SaxParser {
    const parser = allocator.create(SaxParser) catch return null;
    parser.* = SaxParser.init(allocator.*, pool, context, callback) catch return null;
    return parser;
}

pub export fn destroy_parser(parser: *SaxParser) void {
    parser.deinit();
    parser.allocator.destroy(parser);
}

const testing = std.testing;

pub fn handlerCallback(context: ?*anyopaque, entity: Entity) callconv(.C) void {
    const handler: *TestEventHandler = @ptrCast(@alignCast(context));
    handler.handle(entity);
}

fn setupParser(allocator: Allocator, pool: *StringPool, handler: *TestEventHandler) !SaxParser {
    return SaxParser.init(allocator, pool, handler, handlerCallback);
}

pub const TestEventHandler = struct {
    allocator: Allocator,
    attributes: std.ArrayList(Attr),
    texts: std.ArrayList(Text),
    tags: std.ArrayList(Tag),
    proc_insts: std.ArrayList(Text),

    pub fn init(allocator: Allocator) TestEventHandler {
        return .{
            .allocator = allocator,
            .attributes = std.ArrayList(Attr).init(allocator),
            .texts = std.ArrayList(Text).init(allocator),
            .tags = std.ArrayList(Tag).init(allocator),
            .proc_insts = std.ArrayList(Text).init(allocator),
        };
    }

    pub fn deinit(self: *TestEventHandler) void {
        self.attributes.deinit();
        self.texts.deinit();
        self.tags.deinit();
        self.proc_insts.deinit();
    }

    pub fn handle(self: *TestEventHandler, entity: Entity) void {
        switch (entity.tag) {
            .open_tag => {
                self.tags.append(entity.data.open_tag) catch {};
                if (entity.data.open_tag.attributes != null and entity.data.open_tag.attributes_len > 0) {
                    const attrs_slice = entity.data.open_tag.attributes[0..entity.data.open_tag.attributes_len];
                    for (attrs_slice) |attr| {
                        self.attributes.append(attr) catch {};
                    }
                }
            },
            .close_tag => self.tags.append(entity.data.close_tag) catch {},
            .text => self.texts.append(entity.data.text) catch {},
            .comment => self.texts.append(entity.data.comment) catch {},
            .processing_instruction => self.proc_insts.append(entity.data.text) catch {},
            .cdata => self.texts.append(entity.data.cdata) catch {},
        }
    }
};

test "test_attribute" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<body class=\"\"></body> <component data-id=\"user_1234\" key=\"23\" disabled />";
    try parser.write(input);

    const attrs = handler.attributes.items;
    const texts = handler.texts.items;

    try testing.expectEqual(4, attrs.len);
    try testing.expectEqualStrings("", pool.getString(attrs[0].value_id));
    try testing.expectEqual(1, texts.len);
    try testing.expectEqualStrings(" ", pool.getString(texts[0].content_id));
}

test "test_comments" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root><!--Comment without whitespace--><element>content</element><!-- Comment with whitespace --></root>";
    try parser.write(input);

    const texts = handler.texts.items;
    try testing.expectEqual(3, texts.len); // 2 comments + 1 text content

    try testing.expectEqualStrings("Comment without whitespace", pool.getString(texts[0].content_id));

    try testing.expectEqualStrings("content", pool.getString(texts[1].content_id));

    try testing.expectEqualStrings(" Comment with whitespace ", pool.getString(texts[2].content_id));
}

test "test_comment_with_whitespace" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root><!-- This is a comment --></root>";
    try parser.write(input);

    const texts = handler.texts.items;
    try testing.expectEqual(1, texts.len); // 1 comment

    try testing.expectEqualStrings(" This is a comment ", pool.getString(texts[0].content_id));
}

// Other test cases remain unchanged...
test "test_nested_elements" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root><parent><child>content</child></parent></root>";
    try parser.write(input);

    const tags = handler.tags.items;
    try testing.expectEqual(6, tags.len); // 3 open, 3 close

    try testing.expectEqualStrings("root", pool.getString(tags[0].name_id));
    try testing.expectEqualStrings("parent", pool.getString(tags[1].name_id));
    try testing.expectEqualStrings("child", pool.getString(tags[2].name_id));
}

test "test_multiple_attributes" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<element id=\"test\" class=\"main\" data-value=\"123\" enabled=\"true\"></element>";
    try parser.write(input);

    const attrs = handler.attributes.items;
    try testing.expectEqual(4, attrs.len);

    try testing.expectEqualStrings("id", pool.getString(attrs[0].name_id));
    try testing.expectEqualStrings("test", pool.getString(attrs[0].value_id));

    try testing.expectEqualStrings("class", pool.getString(attrs[1].name_id));
    try testing.expectEqualStrings("main", pool.getString(attrs[1].value_id));

    try testing.expectEqualStrings("data-value", pool.getString(attrs[2].name_id));
    try testing.expectEqualStrings("123", pool.getString(attrs[2].value_id));
}

test "test_mixed_quotes_in_attributes" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<element title='He said \"Hello\"' description=\"It's working\"></element>";
    try parser.write(input);

    const attrs = handler.attributes.items;
    try testing.expectEqual(2, attrs.len);

    try testing.expectEqualStrings("title", pool.getString(attrs[0].name_id));
    try testing.expectEqualStrings("He said \"Hello\"", pool.getString(attrs[0].value_id));

    try testing.expectEqualStrings("description", pool.getString(attrs[1].name_id));
    try testing.expectEqualStrings("It's working", pool.getString(attrs[1].value_id));
}

test "test_empty_elements" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root><empty></empty><another/></root>";
    try parser.write(input);

    const tags = handler.tags.items;
    try testing.expectEqual(6, tags.len); // root open, empty open, empty close, another open, another close, root close
}

test "test_whitespace_handling" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input =
        \\<root>
        \\  <element   attr1="value1"   attr2="value2"  >
        \\    Content with spaces
        \\  </element>
        \\</root>
    ;
    try parser.write(input);

    _ = handler.texts.items;
    const attrs = handler.attributes.items;

    try testing.expectEqual(2, attrs.len);
    try testing.expectEqualStrings("attr1", pool.getString(attrs[0].name_id));
    try testing.expectEqualStrings("value1", pool.getString(attrs[0].value_id));
}

test "test_cdata_sections" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root><![CDATA[This is <raw> content & data]]></root>";
    try parser.write(input);

    const texts = handler.texts.items;
    try testing.expectEqual(1, texts.len);

    try testing.expectEqualStrings("This is <raw> content & data", pool.getString(texts[0].content_id));
}

test "test_multiple_cdata_sections" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root><![CDATA[First section]]><![CDATA[Second section]]></root>";
    try parser.write(input);

    const texts = handler.texts.items;
    try testing.expectEqual(2, texts.len);
}

test "test_processing_instructions" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><root><?custom-instruction data?></root>";
    try parser.write(input);

    const proc_insts = handler.proc_insts.items;
    try testing.expectEqual(2, proc_insts.len);
}

test "test_complex_nested_structure" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input =
        \\<?xml version="1.0"?>
        \\<document xmlns="http://example.com">
        \\  <!-- Document header -->
        \\  <header id="main-header" class="primary">
        \\    <title>Test Document</title>
        \\    <metadata>
        \\      <author>Test Author</author>
        \\      <created>2024-01-01</created>
        \\    </metadata>
        \\  </header>
        \\  <body>
        \\    <section id="intro">
        \\      <p>Introduction paragraph with <em>emphasis</em>.</p>
        \\      <![CDATA[Raw content here & special chars < >]]>
        \\    </section>
        \\  </body>
        \\</document>
    ;
    try parser.write(input);

    const tags = handler.tags.items;
    const attrs = handler.attributes.items;
    _ = handler.texts.items;
    const proc_insts = handler.proc_insts.items;

    try testing.expect(tags.len > 10);
    try testing.expect(attrs.len >= 3);
    try testing.expect(proc_insts.len == 1);
}

test "test_edge_case_empty_attributes" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<element empty=\"\" another=\"value\" also-empty=''></element>";
    try parser.write(input);

    const attrs = handler.attributes.items;
    try testing.expectEqual(3, attrs.len);

    try testing.expectEqualStrings("empty", pool.getString(attrs[0].name_id));
    try testing.expectEqualStrings("", pool.getString(attrs[0].value_id));

    try testing.expectEqualStrings("also-empty", pool.getString(attrs[2].name_id));
    try testing.expectEqualStrings("", pool.getString(attrs[2].value_id));
}

test "test_malformed_recovery" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root><unclosed>content<closed></closed></root>";
    try parser.write(input);

    const tags = handler.tags.items;
    try testing.expect(tags.len >= 2);
}

test "test_unicode_content" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root>Unicode: café, 测试, 🌟</root>";
    try parser.write(input);

    const texts = handler.texts.items;
    try testing.expectEqual(1, texts.len);

    try testing.expectEqualStrings("Unicode: café, 测试, 🌟", pool.getString(texts[0].content_id));
}

test "test_namespace_prefixes" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<ns:root xmlns:ns=\"http://example.com\"><ns:child ns:attr=\"value\">content</ns:child></ns:root>";
    try parser.write(input);

    const tags = handler.tags.items;
    const attrs = handler.attributes.items;

    try testing.expectEqualStrings("ns:root", pool.getString(tags[0].name_id));
    try testing.expectEqualStrings("ns:child", pool.getString(tags[1].name_id));

    try testing.expect(attrs.len >= 2);
}

test "test_large_content" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    var large_content = std.ArrayList(u8).init(allocator);
    defer large_content.deinit();

    try large_content.appendSlice("<root>");
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try large_content.appendSlice("<item>content</item>");
    }
    try large_content.appendSlice("</root>");

    try parser.write(large_content.items);

    const tags = handler.tags.items;
    try testing.expectEqual(2002, tags.len);
}

test "test_position_tracking" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input =
        \\<root>
        \\  <element>content</element>
        \\</root>
    ;
    try parser.write(input);

    const tags = handler.tags.items;
    try testing.expect(tags[0].start.line == 1);
    try testing.expect(tags[1].start.line == 2);
}

test "test_mixed_content" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<root>Text before <child>nested</child> text after <another>more</another> final text</root>";
    try parser.write(input);

    const texts = handler.texts.items;
    const tags = handler.tags.items;

    try testing.expect(texts.len >= 4);
    try testing.expect(tags.len == 6);
}

test "attribute unquoted hypenated attribute" {
    const allocator = std.testing.allocator;
    var pool = StringPool.init(allocator);
    defer pool.deinit();
    var handler = TestEventHandler.init(allocator);
    defer handler.deinit();

    var parser = try setupParser(allocator, &pool, &handler);
    defer parser.deinit();

    const input = "<element data-test=\"value with spaces\" hyphen-attr=\"test\" under_score=\"test\" number123=\"test\"></element>";
    try parser.write(input);

    const attrs = handler.attributes.items;
    try testing.expectEqual(4, attrs.len);

    try testing.expectEqualStrings("data-test", pool.getString(attrs[0].name_id));
    try testing.expectEqualStrings("value with spaces", pool.getString(attrs[0].value_id));

    try testing.expectEqualStrings("hyphen-attr", pool.getString(attrs[1].name_id));
    try testing.expectEqualStrings("test", pool.getString(attrs[1].value_id));

    try testing.expectEqualStrings("under_score", pool.getString(attrs[2].name_id));
    try testing.expectEqualStrings("test", pool.getString(attrs[2].value_id));

    try testing.expectEqualStrings("number123", pool.getString(attrs[3].name_id));
    try testing.expectEqualStrings("test", pool.getString(attrs[3].value_id));
}
