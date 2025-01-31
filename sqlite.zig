const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const io = std.io;
const mem = std.mem;
const testing = std.testing;

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const ParsedQuery = @import("query.zig").ParsedQuery;

const Text = @import("query.zig").Text;

pub const errors = @import("errors.zig");
const Error = errors.Error;

const logger = std.log.scoped(.sqlite);

/// ZeroBlob is a blob with a fixed length containing only zeroes.
///
/// A ZeroBlob is intended to serve as a placeholder; content can later be written with incremental i/o.
///
/// Here is an example allowing you to write up to 1024 bytes to a blob with incremental i/o.
///
///    try db.exec("INSERT INTO user VALUES(1, ?)", .{}, .{sqlite.ZeroBlob{ .length = 1024 }});
///    const row_id = db.getLastInsertRowID();
///
///    var blob = try db.openBlob(.main, "user", "data", row_id, .{ .write = true });
///
///    var blob_writer = blob.writer();
///    try blob_writer.writeAll("foobar");
///
///    try blob.close();
///
/// Search for "zeroblob" on https://sqlite.org/c3ref/blob_open.html for more details.
pub const ZeroBlob = struct {
    length: usize,
};

/// Blob is a wrapper for a sqlite BLOB.
///
/// This type is useful when reading or binding data and for doing incremental i/o.
pub const Blob = struct {
    const Self = @This();

    pub const OpenFlags = struct {
        read: bool = true,
        write: bool = false,
    };

    pub const DatabaseName = union(enum) {
        main,
        temp,
        attached: [:0]const u8,

        fn toString(self: @This()) [:0]const u8 {
            return switch (self) {
                .main => "main",
                .temp => "temp",
                .attached => |name| name,
            };
        }
    };

    // Used when reading or binding data.
    data: []const u8,

    // Used for incremental i/o.
    handle: *c.sqlite3_blob = undefined,
    offset: c_int = 0,
    size: c_int = 0,

    /// close closes the blob.
    pub fn close(self: *Self) !void {
        const result = c.sqlite3_blob_close(self.handle);
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }
    }

    pub const Reader = io.Reader(*Self, errors.Error, read);

    /// reader returns a io.Reader.
    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    fn read(self: *Self, buffer: []u8) Error!usize {
        if (self.offset >= self.size) {
            return 0;
        }

        var tmp_buffer = blk: {
            const remaining = @intCast(usize, self.size) - @intCast(usize, self.offset);
            break :blk if (buffer.len > remaining) buffer[0..remaining] else buffer;
        };

        const result = c.sqlite3_blob_read(
            self.handle,
            tmp_buffer.ptr,
            @intCast(c_int, tmp_buffer.len),
            self.offset,
        );
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }

        self.offset += @intCast(c_int, tmp_buffer.len);

        return tmp_buffer.len;
    }

    pub const Writer = io.Writer(*Self, Error, write);

    /// writer returns a io.Writer.
    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    fn write(self: *Self, data: []const u8) Error!usize {
        const result = c.sqlite3_blob_write(
            self.handle,
            data.ptr,
            @intCast(c_int, data.len),
            self.offset,
        );
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }

        self.offset += @intCast(c_int, data.len);

        return data.len;
    }

    /// Reset the offset used for reading and writing.
    pub fn reset(self: *Self) void {
        self.offset = 0;
    }

    /// reopen moves this blob to another row of the same table.
    ///
    /// See https://sqlite.org/c3ref/blob_reopen.html.
    pub fn reopen(self: *Self, row: i64) !void {
        const result = c.sqlite3_blob_reopen(self.handle, row);
        if (result != c.SQLITE_OK) {
            return error.CannotReopenBlob;
        }

        self.size = c.sqlite3_blob_bytes(self.handle);
        self.offset = 0;
    }

    /// open opens a blob for incremental i/o.
    fn open(db: *c.sqlite3, db_name: DatabaseName, table: [:0]const u8, column: [:0]const u8, row: i64, comptime flags: OpenFlags) !Blob {
        comptime if (!flags.read and !flags.write) {
            @compileError("must open a blob for either read, write or both");
        };

        const open_flags: c_int = if (flags.write) 1 else 0;

        var blob: Blob = undefined;
        const result = c.sqlite3_blob_open(
            db,
            db_name.toString(),
            table,
            column,
            row,
            open_flags,
            @ptrCast([*c]?*c.sqlite3_blob, &blob.handle),
        );
        if (result == c.SQLITE_MISUSE) debug.panic("sqlite misuse while opening a blob", .{});
        if (result != c.SQLITE_OK) {
            return error.CannotOpenBlob;
        }

        blob.size = c.sqlite3_blob_bytes(blob.handle);
        blob.offset = 0;

        return blob;
    }
};

/// ThreadingMode controls the threading mode used by SQLite.
///
/// See https://sqlite.org/threadsafe.html
pub const ThreadingMode = enum {
    /// SingleThread makes SQLite unsafe to use with more than a single thread at once.
    SingleThread,
    /// MultiThread makes SQLite safe to use with multiple threads at once provided that
    /// a single database connection is not by more than a single thread at once.
    MultiThread,
    /// Serialized makes SQLite safe to use with multiple threads at once with no restriction.
    Serialized,
};

/// Diagnostics can be used by the library to give more information in case of failures.
pub const Diagnostics = struct {
    message: []const u8 = "",
    err: ?DetailedError = null,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.err) |err| {
            if (self.message.len > 0) {
                _ = try writer.print("{{message: {s}, detailed error: {s}}}", .{ self.message, err });
                return;
            }

            _ = try err.format(fmt, options, writer);
            return;
        }

        if (self.message.len > 0) {
            _ = try writer.write(self.message);
            return;
        }

        _ = try writer.write("none");
    }
};

pub const InitOptions = struct {
    /// mode controls how the database is opened.
    ///
    /// Defaults to a in-memory database.
    mode: Db.Mode = .Memory,

    /// open_flags controls the flags used when opening a database.
    ///
    /// Defaults to a read only database.
    open_flags: Db.OpenFlags = .{},

    /// threading_mode controls the threading mode used by SQLite.
    ///
    /// Defaults to Serialized.
    threading_mode: ThreadingMode = .Serialized,

    /// shared_cache controls whether or not concurrent SQLite
    /// connections share the same cache.
    ///
    /// Defaults to false.
    shared_cache: bool = false,

    /// if provided, diags will be populated in case of failures.
    diags: ?*Diagnostics = null,
};

/// DetailedError contains a SQLite error code and error message.
pub const DetailedError = struct {
    code: usize,
    message: []const u8,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        _ = try writer.print("{{code: {}, message: {s}}}", .{ self.code, self.message });
    }
};

fn isThreadSafe() bool {
    return c.sqlite3_threadsafe() > 0;
}

fn getDetailedErrorFromResultCode(code: c_int) DetailedError {
    return .{
        .code = @intCast(usize, code),
        .message = blk: {
            const msg = c.sqlite3_errstr(code);
            break :blk mem.span(msg);
        },
    };
}

fn getLastDetailedErrorFromDb(db: *c.sqlite3) DetailedError {
    return .{
        .code = @intCast(usize, c.sqlite3_extended_errcode(db)),
        .message = blk: {
            const msg = c.sqlite3_errmsg(db);
            break :blk mem.span(msg);
        },
    };
}

/// Db is a wrapper around a SQLite database, providing high-level functions for executing queries.
/// A Db can be opened with a file database or a in-memory database:
///
///     // File database
///     var db = try sqlite.Db.init(.{ .mode = .{ .File = "/tmp/data.db" } });
///
///     // In memory database
///     var db = try sqlite.Db.init(.{ .mode = .{ .Memory = {} } });
///
pub const Db = struct {
    const Self = @This();

    db: *c.sqlite3,

    /// Mode determines how the database will be opened.
    ///
    /// * File means opening the database at this path with sqlite3_open_v2.
    /// * Memory means opening the database in memory.
    ///   This works by opening the :memory: path with sqlite3_open_v2 with the flag SQLITE_OPEN_MEMORY.
    pub const Mode = union(enum) {
        File: [:0]const u8,
        Memory,
    };

    /// OpenFlags contains various flags used when opening a SQLite databse.
    ///
    /// These flags partially map to the flags defined in https://sqlite.org/c3ref/open.html
    ///  * write=false and create=false means SQLITE_OPEN_READONLY
    ///  * write=true and create=false means SQLITE_OPEN_READWRITE
    ///  * write=true and create=true means SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE
    pub const OpenFlags = struct {
        write: bool = false,
        create: bool = false,
    };

    /// init creates a database with the provided options.
    pub fn init(options: InitOptions) !Self {
        var dummy_diags = Diagnostics{};
        var diags = options.diags orelse &dummy_diags;

        // Validate the threading mode
        if (options.threading_mode != .SingleThread and !isThreadSafe()) {
            return error.SQLiteBuildNotThreadSafe;
        }

        // Compute the flags
        var flags: c_int = c.SQLITE_OPEN_URI;
        flags |= @as(c_int, if (options.open_flags.write) c.SQLITE_OPEN_READWRITE else c.SQLITE_OPEN_READONLY);
        if (options.open_flags.create) {
            flags |= c.SQLITE_OPEN_CREATE;
        }
        if (options.shared_cache) {
            flags |= c.SQLITE_OPEN_SHAREDCACHE;
        }
        switch (options.threading_mode) {
            .MultiThread => flags |= c.SQLITE_OPEN_NOMUTEX,
            .Serialized => flags |= c.SQLITE_OPEN_FULLMUTEX,
            else => {},
        }

        switch (options.mode) {
            .File => |path| {
                logger.info("opening {s}", .{path});

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(path, &db, flags, null);
                if (result != c.SQLITE_OK or db == null) {
                    if (db) |v| {
                        diags.err = getLastDetailedErrorFromDb(v);
                    } else {
                        diags.err = getDetailedErrorFromResultCode(result);
                    }
                    return errors.errorFromResultCode(result);
                }

                return Self{ .db = db.? };
            },
            .Memory => {
                logger.info("opening in memory", .{});

                flags |= c.SQLITE_OPEN_MEMORY;

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(":memory:", &db, flags, null);
                if (result != c.SQLITE_OK or db == null) {
                    if (db) |v| {
                        diags.err = getLastDetailedErrorFromDb(v);
                    } else {
                        diags.err = getDetailedErrorFromResultCode(result);
                    }
                    return errors.errorFromResultCode(result);
                }

                return Self{ .db = db.? };
            },
        }
    }

    /// deinit closes the database.
    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);
    }

    // getDetailedError returns the detailed error for the last API call if it failed.
    pub fn getDetailedError(self: *Self) DetailedError {
        return getLastDetailedErrorFromDb(self.db);
    }

    fn getPragmaQuery(comptime buf: []u8, comptime name: []const u8, comptime arg: ?[]const u8) []const u8 {
        if (arg) |a| {
            return try std.fmt.bufPrint(buf, "PRAGMA {s} = {s}", .{ name, a });
        }
        return try std.fmt.bufPrint(buf, "PRAGMA {s}", .{name});
    }

    /// getLastInsertRowID returns the last inserted rowid.
    pub fn getLastInsertRowID(self: *Self) i64 {
        const rowid = c.sqlite3_last_insert_rowid(self.db);
        return rowid;
    }

    /// pragmaAlloc is like `pragma` but can allocate memory.
    ///
    /// Useful when the pragma command returns text, for example:
    ///
    ///     const journal_mode = try db.pragma([]const u8, allocator, .{}, "journal_mode", null);
    ///
    pub fn pragmaAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, comptime name: []const u8, comptime arg: ?[]const u8) !?Type {
        comptime var buf: [1024]u8 = undefined;
        comptime var query = getPragmaQuery(&buf, name, arg);

        var stmt = try self.prepare(query);
        defer stmt.deinit();

        return try stmt.oneAlloc(Type, allocator, options, .{});
    }

    /// pragma is a convenience function to use the PRAGMA statement.
    ///
    /// Here is how to set a pragma value:
    ///
    ///     try db.pragma(void, .{}, "foreign_keys", "1");
    ///
    /// Here is how to query a pragama value:
    ///
    ///     const journal_mode = try db.pragma([128:0]const u8, .{}, "journal_mode", null);
    ///
    /// The pragma name must be known at comptime.
    ///
    /// This cannot allocate memory. If your pragma command returns text you must use an array or call `pragmaAlloc`.
    pub fn pragma(self: *Self, comptime Type: type, options: QueryOptions, comptime name: []const u8, comptime arg: ?[]const u8) !?Type {
        comptime var buf: [1024]u8 = undefined;
        comptime var query = getPragmaQuery(&buf, name, arg);

        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();

        return try stmt.one(Type, options, .{});
    }

    /// exec is a convenience function which prepares a statement and executes it directly.
    pub fn exec(self: *Self, comptime query: []const u8, options: QueryOptions, values: anytype) !void {
        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();
        try stmt.exec(options, values);
    }

    /// one is a convenience function which prepares a statement and reads a single row from the result set.
    pub fn one(self: *Self, comptime Type: type, comptime query: []const u8, options: QueryOptions, values: anytype) !?Type {
        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();
        return try stmt.one(Type, options, values);
    }

    /// oneAlloc is like `one` but can allocate memory.
    pub fn oneAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, comptime query: []const u8, options: QueryOptions, values: anytype) !?Type {
        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();
        return try stmt.oneAlloc(Type, allocator, options, values);
    }

    /// prepareWithDiags is like `prepare` but takes an additional options argument.
    pub fn prepareWithDiags(self: *Self, comptime query: []const u8, options: QueryOptions) !blk: {
        @setEvalBranchQuota(100000);
        break :blk Statement(.{}, ParsedQuery.from(query));
    } {
        @setEvalBranchQuota(100000);
        const parsed_query = ParsedQuery.from(query);
        return Statement(.{}, comptime parsed_query).prepare(self, options, 0);
    }

    /// prepare prepares a statement for the `query` provided.
    ///
    /// The query is analysed at comptime to search for bind markers.
    /// prepare enforces having as much fields in the `values` tuple as there are bind markers.
    ///
    /// Example usage:
    ///
    ///     var stmt = try db.prepare("INSERT INTO foo(id, name) VALUES(?, ?)");
    ///     defer stmt.deinit();
    ///
    /// The statement returned is only compatible with the number of bind markers in the input query.
    /// This is done because we type check the bind parameters when executing the statement later.
    ///
    /// If you want additional error information in case of failures, use `prepareWithDiags`.
    pub fn prepare(self: *Self, comptime query: []const u8) !blk: {
        @setEvalBranchQuota(100000);
        break :blk Statement(.{}, ParsedQuery.from(query));
    } {
        @setEvalBranchQuota(100000);
        const parsed_query = ParsedQuery.from(query);
        return Statement(.{}, comptime parsed_query).prepare(self, .{}, 0);
    }

    /// rowsAffected returns the number of rows affected by the last statement executed.
    pub fn rowsAffected(self: *Self) usize {
        return @intCast(usize, c.sqlite3_changes(self.db));
    }

    /// openBlob opens a blob for incremental i/o.
    ///
    /// Incremental i/o enables writing and reading data using a std.io.Writer and std.io.Reader:
    ///  * the writer type wraps sqlite3_blob_write, see https://sqlite.org/c3ref/blob_write.html
    ///  * the reader type wraps sqlite3_blob_read, see https://sqlite.org/c3ref/blob_read.html
    ///
    /// Note that:
    /// * the blob must exist before writing; you must use INSERT to create one first (either with data or using a placeholder with ZeroBlob).
    /// * the blob is not extensible, if you want to change the blob size you must use an UPDATE statement.
    ///
    /// You can get a std.io.Writer to write data to the blob:
    ///
    ///     var blob = try db.openBlob(.main, "mytable", "mycolumn", 1, .{ .write = true });
    ///     var blob_writer = blob.writer();
    ///
    ///     try blob_writer.writeAll(my_data);
    ///
    /// You can get a std.io.Reader to read the blob data:
    ///
    ///     var blob = try db.openBlob(.main, "mytable", "mycolumn", 1, .{});
    ///     var blob_reader = blob.reader();
    ///
    ///     const data = try blob_reader.readAlloc(allocator);
    ///
    /// See https://sqlite.org/c3ref/blob_open.html for more details on incremental i/o.
    ///
    pub fn openBlob(self: *Self, db_name: Blob.DatabaseName, table: [:0]const u8, column: [:0]const u8, row: i64, comptime flags: Blob.OpenFlags) !Blob {
        return Blob.open(self.db, db_name, table, column, row, flags);
    }
};

pub const QueryOptions = struct {
    /// if provided, diags will be populated in case of failures.
    diags: ?*Diagnostics = null,
};

/// Iterator allows iterating over a result set.
///
/// Each call to `next` returns the next row of the result set, or null if the result set is exhausted.
/// Each row will have the type `Type` so the columns returned in the result set must be compatible with this type.
///
/// Here is an example of how to use the iterator:
///
///     const User = struct {
///         name: Text,
///         age: u16,
///     };
///
///     var stmt = try db.prepare("SELECT name, age FROM user");
///     defer stmt.deinit();
///
///     var iter = try stmt.iterator(User, .{});
///     while (try iter.next(.{})) |row| {
///         ...
///     }
///
/// The iterator _must not_ outlive the statement.
pub fn Iterator(comptime Type: type) type {
    return struct {
        const Self = @This();

        const TypeInfo = @typeInfo(Type);

        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,

        // next scans the next row using the prepared statement.
        // If it returns null iterating is done.
        //
        // This cannot allocate memory. If you need to read TEXT or BLOB columns you need to use arrays or alternatively call nextAlloc.
        pub fn next(self: *Self, options: QueryOptions) !?Type {
            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            var result = c.sqlite3_step(self.stmt);
            if (result == c.SQLITE_DONE) {
                return null;
            }
            if (result != c.SQLITE_ROW) {
                diags.err = getLastDetailedErrorFromDb(self.db);
                return errors.errorFromResultCode(result);
            }

            const columns = c.sqlite3_column_count(self.stmt);

            switch (TypeInfo) {
                .Int => {
                    debug.assert(columns == 1);
                    return try self.readInt(Type, 0);
                },
                .Float => {
                    debug.assert(columns == 1);
                    return try self.readFloat(Type, 0);
                },
                .Bool => {
                    debug.assert(columns == 1);
                    return try self.readBool(0);
                },
                .Void => {
                    debug.assert(columns == 1);
                },
                .Array => {
                    debug.assert(columns == 1);
                    return try self.readArray(Type, 0);
                },
                .Enum => |TI| {
                    debug.assert(columns == 1);

                    if (comptime std.meta.trait.isZigString(Type.BaseType)) {
                        @compileError("cannot read into type " ++ @typeName(Type) ++ " ; BaseType " ++ @typeName(Type.BaseType) ++ " requires allocation, use nextAlloc or oneAlloc");
                    }

                    if (@typeInfo(Type.BaseType) == .Int) {
                        const innervalue = try self.readField(Type.BaseType, options, 0);
                        return @intToEnum(Type, @intCast(TI.tag_type, innervalue));
                    }

                    @compileError("enum column " ++ @typeName(Type) ++ " must have a BaseType of either string or int");
                },
                .Struct => {
                    std.debug.assert(columns == TypeInfo.Struct.fields.len);
                    return try self.readStruct(options);
                },
                else => @compileError("cannot read into type " ++ @typeName(Type) ++ " ; if dynamic memory allocation is required use nextAlloc or oneAlloc"),
            }
        }

        // nextAlloc is like `next` but can allocate memory.
        pub fn nextAlloc(self: *Self, allocator: mem.Allocator, options: QueryOptions) !?Type {
            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            var result = c.sqlite3_step(self.stmt);
            if (result == c.SQLITE_DONE) {
                return null;
            }
            if (result != c.SQLITE_ROW) {
                diags.err = getLastDetailedErrorFromDb(self.db);
                return errors.errorFromResultCode(result);
            }

            const columns = c.sqlite3_column_count(self.stmt);

            switch (Type) {
                []const u8, []u8 => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Type, allocator, 0, .Text);
                },
                Blob => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Blob, allocator, 0, .Blob);
                },
                Text => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Text, allocator, 0, .Text);
                },
                else => {},
            }

            switch (TypeInfo) {
                .Int => {
                    debug.assert(columns == 1);
                    return try self.readInt(Type, 0);
                },
                .Float => {
                    debug.assert(columns == 1);
                    return try self.readFloat(Type, 0);
                },
                .Bool => {
                    debug.assert(columns == 1);
                    return try self.readBool(0);
                },
                .Void => {
                    debug.assert(columns == 1);
                },
                .Array => {
                    debug.assert(columns == 1);
                    return try self.readArray(Type, 0);
                },
                .Pointer => {
                    debug.assert(columns == 1);
                    return try self.readPointer(Type, .{
                        .allocator = allocator,
                    }, 0);
                },
                .Enum => |TI| {
                    debug.assert(columns == 1);

                    const innervalue = try self.readField(Type.BaseType, .{
                        .allocator = allocator,
                    }, 0);

                    if (comptime std.meta.trait.isZigString(Type.BaseType)) {
                        return std.meta.stringToEnum(Type, innervalue) orelse unreachable;
                    }
                    if (@typeInfo(Type.BaseType) == .Int) {
                        return @intToEnum(Type, @intCast(TI.tag_type, innervalue));
                    }
                    @compileError("enum column " ++ @typeName(Type) ++ " must have a BaseType of either string or int");
                },
                .Struct => {
                    std.debug.assert(columns == TypeInfo.Struct.fields.len);
                    return try self.readStruct(.{
                        .allocator = allocator,
                    });
                },
                else => @compileError("cannot read into type " ++ @typeName(Type)),
            }
        }

        // readArray reads a sqlite BLOB or TEXT column into an array of u8.
        //
        // We also require the array to be the exact size of the data, or have a sentinel;
        // otherwise we have no way of communicating the end of the data to the caller.
        //
        // If the array is too small for the data an error will be returned.
        fn readArray(self: *Self, comptime ArrayType: type, _i: usize) !ArrayType {
            const i = @intCast(c_int, _i);
            const type_info = @typeInfo(ArrayType);

            var ret: ArrayType = undefined;
            switch (type_info) {
                .Array => |arr| {
                    switch (arr.child) {
                        u8 => {
                            const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));
                            if (arr.sentinel == null) {
                                if (size != arr.len) return error.ArraySizeMismatch;
                            } else if (size >= @as(usize, arr.len)) {
                                return error.ArrayTooSmall;
                            }

                            const data = c.sqlite3_column_blob(self.stmt, i);
                            const ptr = @ptrCast([*c]const u8, data)[0..size];

                            mem.copy(u8, ret[0..], ptr);
                            if (arr.sentinel) |s| {
                                ret[size] = s;
                            }
                        },
                        else => @compileError("cannot read into array of " ++ @typeName(arr.child)),
                    }
                },
                else => @compileError("cannot read into type " ++ @typeName(ret)),
            }
            return ret;
        }

        // readInt reads a sqlite INTEGER column into an integer.
        //
        // TODO remove the workaround once https://github.com/ziglang/zig/issues/5149 is resolved or if we actually return an error
        fn readInt(self: *Self, comptime IntType: type, i: usize) error{Workaround}!IntType {
            const n = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return @intCast(IntType, n);
        }

        // readFloat reads a sqlite REAL column into a float.
        //
        // TODO remove the workaround once https://github.com/ziglang/zig/issues/5149 is resolved or if we actually return an error
        fn readFloat(self: *Self, comptime FloatType: type, i: usize) error{Workaround}!FloatType {
            const d = c.sqlite3_column_double(self.stmt, @intCast(c_int, i));
            return @floatCast(FloatType, d);
        }

        // readFloat reads a sqlite INTEGER column into a bool (true is anything > 0, false is anything <= 0).
        //
        // TODO remove the workaround once https://github.com/ziglang/zig/issues/5149 is resolved or if we actually return an error
        fn readBool(self: *Self, i: usize) error{Workaround}!bool {
            const d = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return d > 0;
        }

        const ReadBytesMode = enum {
            Blob,
            Text,
        };

        // dupeWithSentinel is like dupe/dupeZ but allows for any sentinel value.
        fn dupeWithSentinel(comptime SliceType: type, allocator: mem.Allocator, data: []const u8) !SliceType {
            switch (@typeInfo(SliceType)) {
                .Pointer => |ptr_info| {
                    if (ptr_info.sentinel) |sentinel| {
                        const slice = try allocator.alloc(u8, data.len + 1);
                        mem.copy(u8, slice, data);
                        slice[data.len] = sentinel;

                        return slice[0..data.len :sentinel];
                    } else {
                        return try allocator.dupe(u8, data);
                    }
                },
                else => @compileError("cannot dupe type " ++ @typeName(SliceType)),
            }
        }

        // readBytes reads a sqlite BLOB or TEXT column.
        //
        // The mode controls which sqlite function is used to retrieve the data:
        // * .Blob uses sqlite3_column_blob
        // * .Text uses sqlite3_column_text
        //
        // When using .Blob you can only read into either []const u8, []u8 or Blob.
        // When using .Text you can only read into either []const u8, []u8 or Text.
        //
        // The options must contain an `allocator` field which will be used to create a copy of the data.
        fn readBytes(self: *Self, comptime BytesType: type, allocator: mem.Allocator, _i: usize, comptime mode: ReadBytesMode) !BytesType {
            const i = @intCast(c_int, _i);

            switch (mode) {
                .Blob => {
                    const data = c.sqlite3_column_blob(self.stmt, i);
                    if (data == null) {
                        return switch (BytesType) {
                            Text, Blob => .{ .data = try allocator.dupe(u8, "") },
                            else => try dupeWithSentinel(BytesType, allocator, ""),
                        };
                    }

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));
                    const ptr = @ptrCast([*c]const u8, data)[0..size];

                    if (BytesType == Blob) {
                        return Blob{ .data = try allocator.dupe(u8, ptr) };
                    }
                    return try dupeWithSentinel(BytesType, allocator, ptr);
                },
                .Text => {
                    const data = c.sqlite3_column_text(self.stmt, i);
                    if (data == null) {
                        return switch (BytesType) {
                            Text, Blob => .{ .data = try allocator.dupe(u8, "") },
                            else => try dupeWithSentinel(BytesType, allocator, ""),
                        };
                    }

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));
                    const ptr = @ptrCast([*c]const u8, data)[0..size];

                    if (BytesType == Text) {
                        return Text{ .data = try allocator.dupe(u8, ptr) };
                    }
                    return try dupeWithSentinel(BytesType, allocator, ptr);
                },
            }
        }

        fn readPointer(self: *Self, comptime PointerType: type, options: anytype, i: usize) !PointerType {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readPointer must be a struct");
            }
            if (!comptime std.meta.trait.hasField("allocator")(@TypeOf(options))) {
                @compileError("options passed to readPointer must have an allocator field");
            }

            var ret: PointerType = undefined;
            switch (@typeInfo(PointerType)) {
                .Pointer => |ptr| {
                    switch (ptr.size) {
                        .One => {
                            ret = try options.allocator.create(ptr.child);
                            errdefer options.allocator.destroy(ret);

                            ret.* = try self.readField(ptr.child, options, i);
                        },
                        .Slice => switch (ptr.child) {
                            u8 => ret = try self.readBytes(PointerType, options.allocator, i, .Text),
                            else => @compileError("cannot read pointer of type " ++ @typeName(PointerType)),
                        },
                        else => @compileError("cannot read pointer of type " ++ @typeName(PointerType)),
                    }
                },
                else => @compileError("cannot read pointer of type " ++ @typeName(PointerType)),
            }

            return ret;
        }

        fn readOptional(self: *Self, comptime OptionalType: type, options: anytype, _i: usize) !OptionalType {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readOptional must be a struct");
            }

            var ret: OptionalType = undefined;
            switch (@typeInfo(OptionalType)) {
                .Optional => |opt| {
                    // Easy way to know if the column represents a null value.
                    const value = c.sqlite3_column_value(self.stmt, @intCast(c_int, _i));
                    const datatype = c.sqlite3_value_type(value);

                    if (datatype == c.SQLITE_NULL) {
                        return null;
                    } else {
                        const val = try self.readField(opt.child, options, _i);
                        ret = val;
                        return ret;
                    }
                },
                else => @compileError("cannot read optional of type " ++ @typeName(OptionalType)),
            }
        }

        // readStruct reads an entire sqlite row into a struct.
        //
        // Each field correspond to a column; its position in the struct determines the column used for it.
        // For example, given the following query:
        //
        //   SELECT id, name, age FROM user
        //
        // The struct must have the following fields:
        //
        //   struct {
        //     id: usize,
        //     name: []const u8,
        //     age: u16,
        //   }
        //
        // The field `id` will be associated with the column `id` and so on.
        //
        // This function relies on the fact that there are the same number of fields than columns and
        // that the order is correct.
        //
        // TODO(vincent): add comptime checks for the fields/columns.
        fn readStruct(self: *Self, options: anytype) !Type {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readStruct must be a struct");
            }

            var value: Type = undefined;

            inline for (@typeInfo(Type).Struct.fields) |field, _i| {
                const i = @as(usize, _i);

                const ret = try self.readField(field.field_type, options, i);

                @field(value, field.name) = ret;
            }

            return value;
        }

        fn readField(self: *Self, comptime FieldType: type, options: anytype, i: usize) !FieldType {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readField must be a struct");
            }

            const field_type_info = @typeInfo(FieldType);

            return switch (FieldType) {
                Blob => blk: {
                    if (!comptime std.meta.trait.hasField("allocator")(@TypeOf(options))) {
                        @compileError("options passed to readPointer must have an allocator field when reading a Blob");
                    }
                    break :blk try self.readBytes(Blob, options.allocator, i, .Blob);
                },
                Text => blk: {
                    if (!comptime std.meta.trait.hasField("allocator")(@TypeOf(options))) {
                        @compileError("options passed to readField must have an allocator field when reading a Text");
                    }
                    break :blk try self.readBytes(Text, options.allocator, i, .Text);
                },
                else => switch (field_type_info) {
                    .Int => try self.readInt(FieldType, i),
                    .Float => try self.readFloat(FieldType, i),
                    .Bool => try self.readBool(i),
                    .Void => {},
                    .Array => try self.readArray(FieldType, i),
                    .Pointer => try self.readPointer(FieldType, options, i),
                    .Optional => try self.readOptional(FieldType, options, i),
                    .Enum => |TI| {
                        const innervalue = try self.readField(FieldType.BaseType, options, i);

                        if (comptime std.meta.trait.isZigString(FieldType.BaseType)) {
                            return std.meta.stringToEnum(FieldType, innervalue) orelse unreachable;
                        }
                        if (@typeInfo(FieldType.BaseType) == .Int) {
                            return @intToEnum(FieldType, @intCast(TI.tag_type, innervalue));
                        }
                        @compileError("enum column " ++ @typeName(FieldType) ++ " must have a BaseType of either string or int");
                    },
                    else => @compileError("cannot populate field of type " ++ @typeName(FieldType)),
                },
            };
        }
    };
}

pub const StatementOptions = struct {};

/// Statement is a wrapper around a SQLite statement, providing high-level functions to execute
/// a statement and retrieve rows for SELECT queries.
///
/// The exec function can be used to execute a query which does not return rows:
///
///     var stmt = try db.prepare("UPDATE foo SET id = ? WHERE name = ?");
///     defer stmt.deinit();
///
///     try stmt.exec(.{
///         .id = 200,
///         .name = "José",
///     });
///
/// The one function can be used to select a single row:
///
///     var stmt = try db.prepare("SELECT name FROM foo WHERE id = ?");
///     defer stmt.deinit();
///
///     const name = try stmt.one([]const u8, .{}, .{ .id = 200 });
///
/// The all function can be used to select all rows:
///
///     var stmt = try db.prepare("SELECT id, name FROM foo");
///     defer stmt.deinit();
///
///     const Row = struct {
///         id: usize,
///         name: []const u8,
///     };
///     const rows = try stmt.all(Row, .{ .allocator = allocator }, .{});
///
/// Look at each function for more complete documentation.
///
pub fn Statement(comptime opts: StatementOptions, comptime query: ParsedQuery) type {
    _ = opts;

    return struct {
        const Self = @This();

        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,

        fn prepare(db: *Db, options: QueryOptions, flags: c_uint) !Self {
            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            var stmt = blk: {
                const real_query = query.getQuery();

                var tmp: ?*c.sqlite3_stmt = undefined;
                const result = c.sqlite3_prepare_v3(
                    db.db,
                    real_query.ptr,
                    @intCast(c_int, real_query.len),
                    flags,
                    &tmp,
                    null,
                );
                if (result != c.SQLITE_OK) {
                    diags.err = getLastDetailedErrorFromDb(db.db);
                    return errors.errorFromResultCode(result);
                }
                break :blk tmp.?;
            };

            return Self{
                .db = db.db,
                .stmt = stmt,
            };
        }

        /// deinit releases the prepared statement.
        ///
        /// After a call to `deinit` the statement must not be used.
        pub fn deinit(self: *Self) void {
            const result = c.sqlite3_finalize(self.stmt);
            if (result != c.SQLITE_OK) {
                const detailed_error = getLastDetailedErrorFromDb(self.db);
                logger.err("unable to finalize prepared statement, result: {}, detailed error: {}", .{ result, detailed_error });
            }
        }

        /// reset resets the prepared statement to make it reusable.
        pub fn reset(self: *Self) void {
            const result = c.sqlite3_clear_bindings(self.stmt);
            if (result != c.SQLITE_OK) {
                const detailed_error = getLastDetailedErrorFromDb(self.db);
                logger.err("unable to clear prepared statement bindings, result: {}, detailed error: {}", .{ result, detailed_error });
            }

            const result2 = c.sqlite3_reset(self.stmt);
            if (result2 != c.SQLITE_OK) {
                const detailed_error = getLastDetailedErrorFromDb(self.db);
                logger.err("unable to reset prepared statement, result: {}, detailed error: {}", .{ result2, detailed_error });
            }
        }

        /// bind binds values to every bind marker in the prepared statement.
        ///
        /// The `values` variable must be a struct where each field has the type of the corresponding bind marker.
        /// For example this query:
        ///   SELECT 1 FROM user WHERE name = ?{text} AND age < ?{u32}
        ///
        /// Has two bind markers, so `values` must have at least the following fields:
        ///   struct {
        ///     name: Text,
        ///     age: u32
        ///   }
        ///
        /// The types are checked at comptime.
        fn bind(self: *Self, values: anytype) void {
            const StructType = @TypeOf(values);
            const StructTypeInfo = @typeInfo(StructType).Struct;

            if (comptime query.nb_bind_markers != StructTypeInfo.fields.len) {
                @compileError(comptime std.fmt.comptimePrint("number of bind markers ({d}) not equal to number of fields ({d})", .{
                    query.nb_bind_markers,
                    StructTypeInfo.fields.len,
                }));
            }

            inline for (StructTypeInfo.fields) |struct_field, _i| {
                const bind_marker = query.bind_markers[_i];
                switch (bind_marker) {
                    .Typed => |typ| {
                        const FieldTypeInfo = @typeInfo(struct_field.field_type);
                        switch (FieldTypeInfo) {
                            .Struct, .Enum, .Union => comptime assertMarkerType(
                                if (@hasDecl(struct_field.field_type, "BaseType")) struct_field.field_type.BaseType else struct_field.field_type,
                                typ,
                            ),
                            else => comptime assertMarkerType(struct_field.field_type, typ),
                        }
                    },
                    .Untyped => {},
                }

                const field_value = @field(values, struct_field.name);

                self.bindField(struct_field.field_type, struct_field.name, _i, field_value);
            }
        }

        fn assertMarkerType(comptime Actual: type, comptime Expected: type) void {
            if (Actual != Expected) {
                @compileError("value type " ++ @typeName(Actual) ++ " is not the bind marker type " ++ @typeName(Expected));
            }
        }

        fn bindField(self: *Self, comptime FieldType: type, comptime field_name: []const u8, i: c_int, field: FieldType) void {
            const field_type_info = @typeInfo(FieldType);
            const column = i + 1;

            switch (FieldType) {
                Text => _ = c.sqlite3_bind_text(self.stmt, column, field.data.ptr, @intCast(c_int, field.data.len), null),
                Blob => _ = c.sqlite3_bind_blob(self.stmt, column, field.data.ptr, @intCast(c_int, field.data.len), null),
                ZeroBlob => _ = c.sqlite3_bind_zeroblob64(self.stmt, column, field.length),
                else => switch (field_type_info) {
                    .Int, .ComptimeInt => _ = c.sqlite3_bind_int64(self.stmt, column, @intCast(c_longlong, field)),
                    .Float, .ComptimeFloat => _ = c.sqlite3_bind_double(self.stmt, column, field),
                    .Bool => _ = c.sqlite3_bind_int64(self.stmt, column, @boolToInt(field)),
                    .Pointer => |ptr| switch (ptr.size) {
                        .One => self.bindField(ptr.child, field_name, i, field.*),
                        .Slice => switch (ptr.child) {
                            u8 => {
                                _ = c.sqlite3_bind_text(self.stmt, column, field.ptr, @intCast(c_int, field.len), null);
                            },
                            else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                        },
                        else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                    },
                    .Array => |arr| {
                        switch (arr.child) {
                            u8 => {
                                const data: []const u8 = field[0..field.len];

                                _ = c.sqlite3_bind_text(self.stmt, column, data.ptr, @intCast(c_int, data.len), null);
                            },
                            else => @compileError("cannot bind field " ++ field_name ++ " of type array of " ++ @typeName(arr.child)),
                        }
                    },
                    .Optional => |opt| if (field) |non_null_field| {
                        self.bindField(opt.child, field_name, i, non_null_field);
                    } else {
                        _ = c.sqlite3_bind_null(self.stmt, column);
                    },
                    .Null => _ = c.sqlite3_bind_null(self.stmt, column),
                    .Enum => {
                        if (comptime std.meta.trait.isZigString(FieldType.BaseType)) {
                            return self.bindField(FieldType.BaseType, field_name, i, @tagName(field));
                        }
                        if (@typeInfo(FieldType.BaseType) == .Int) {
                            return self.bindField(FieldType.BaseType, field_name, i, @enumToInt(field));
                        }
                        @compileError("enum column " ++ @typeName(FieldType) ++ " must have a BaseType of either string or int to bind");
                    },
                    else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                },
            }
        }

        /// exec executes a statement which does not return data.
        ///
        /// The `options` tuple is used to provide additional state in some cases.
        ///
        /// The `values` variable is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        pub fn exec(self: *Self, options: QueryOptions, values: anytype) !void {
            self.bind(values);

            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            const result = c.sqlite3_step(self.stmt);
            switch (result) {
                c.SQLITE_DONE => {},
                else => {
                    diags.err = getLastDetailedErrorFromDb(self.db);
                    return errors.errorFromResultCode(result);
                },
            }
        }

        /// iterator returns an iterator to read data from the result set, one row at a time.
        ///
        /// The data in the row is used to populate a value of the type `Type`.
        /// This means that `Type` must have as many fields as is returned in the query
        /// executed by this statement.
        /// This also means that the type of each field must be compatible with the SQLite type.
        ///
        /// Here is an example of how to use the iterator:
        ///
        ///     var iter = try stmt.iterator(usize, .{});
        ///     while (try iter.next(.{})) |row| {
        ///         ...
        ///     }
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// The iterator _must not_ outlive the statement.
        pub fn iterator(self: *Self, comptime Type: type, values: anytype) !Iterator(Type) {
            self.bind(values);

            var res: Iterator(Type) = undefined;
            res.db = self.db;
            res.stmt = self.stmt;

            return res;
        }

        /// one reads a single row from the result set of this statement.
        ///
        /// The data in the row is used to populate a value of the type `Type`.
        /// This means that `Type` must have as many fields as is returned in the query
        /// executed by this statement.
        /// This also means that the type of each field must be compatible with the SQLite type.
        ///
        /// Here is an example of how to use an anonymous struct type:
        ///
        ///     const row = try stmt.one(
        ///         struct {
        ///             id: usize,
        ///             name: [400]u8,
        ///             age: usize,
        ///         },
        ///         .{},
        ///         .{ .foo = "bar", .age = 500 },
        ///     );
        ///
        /// The `options` tuple is used to provide additional state in some cases.
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// This cannot allocate memory. If you need to read TEXT or BLOB columns you need to use arrays or alternatively call `oneAlloc`.
        pub fn one(self: *Self, comptime Type: type, options: QueryOptions, values: anytype) !?Type {
            var iter = try self.iterator(Type, values);

            const row = (try iter.next(options)) orelse return null;
            return row;
        }

        /// oneAlloc is like `one` but can allocate memory.
        pub fn oneAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, values: anytype) !?Type {
            var iter = try self.iterator(Type, values);

            const row = (try iter.nextAlloc(allocator, options)) orelse return null;
            return row;
        }

        /// all reads all rows from the result set of this statement.
        ///
        /// The data in each row is used to populate a value of the type `Type`.
        /// This means that `Type` must have as many fields as is returned in the query
        /// executed by this statement.
        /// This also means that the type of each field must be compatible with the SQLite type.
        ///
        /// Here is an example of how to use an anonymous struct type:
        ///
        ///     const rows = try stmt.all(
        ///         struct {
        ///             id: usize,
        ///             name: []const u8,
        ///             age: usize,
        ///         },
        ///         allocator,
        ///         .{},
        ///         .{ .foo = "bar", .age = 500 },
        ///     );
        ///
        /// The `options` tuple is used to provide additional state in some cases.
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// Note that this allocates all rows into a single slice: if you read a lot of data this can use a lot of memory.
        pub fn all(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, values: anytype) ![]Type {
            var iter = try self.iterator(Type, values);

            var rows = std.ArrayList(Type).init(allocator);
            while (try iter.nextAlloc(allocator, options)) |row| {
                try rows.append(row);
            }

            return rows.toOwnedSlice();
        }
    };
}

const TestUser = struct {
    name: []const u8,
    id: usize,
    age: usize,
    weight: f32,
    favorite_color: Color,

    pub const Color = enum {
        red,
        majenta,
        violet,
        indigo,
        blue,
        cyan,
        green,
        lime,
        yellow,
        //
        orange,
        //

        pub const BaseType = []const u8;
    };
};

const test_users = &[_]TestUser{
    .{ .name = "Vincent", .id = 20, .age = 33, .weight = 85.4, .favorite_color = .violet },
    .{ .name = "Julien", .id = 40, .age = 35, .weight = 100.3, .favorite_color = .green },
    .{ .name = "José", .id = 60, .age = 40, .weight = 240.2, .favorite_color = .indigo },
};

fn createTestTables(db: *Db) !void {
    const AllDDL = &[_][]const u8{
        "DROP TABLE IF EXISTS user",
        "DROP TABLE IF EXISTS article",
        "DROP TABLE IF EXISTS test_blob",
        \\CREATE TABLE user(
        \\ name text,
        \\ id integer PRIMARY KEY,
        \\ age integer,
        \\ weight real,
        \\ favorite_color text
        \\)
        ,
        \\CREATE TABLE article(
        \\  id integer PRIMARY KEY,
        \\  author_id integer,
        \\  data text,
        \\  is_published integer,
        \\  FOREIGN KEY(author_id) REFERENCES user(id)
        \\)
    };

    // Create the tables
    inline for (AllDDL) |ddl| {
        try db.exec(ddl, .{}, .{});
    }
}

fn addTestData(db: *Db) !void {
    try createTestTables(db);

    for (test_users) |user| {
        try db.exec("INSERT INTO user(name, id, age, weight, favorite_color) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32}, ?{[]const u8})", .{}, user);

        const rows_inserted = db.rowsAffected();
        try testing.expectEqual(@as(usize, 1), rows_inserted);
    }
}

test "sqlite: db init" {
    var db = try getTestDb();
    _ = db;
}

test "sqlite: db pragma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();

    const foreign_keys = try db.pragma(usize, .{}, "foreign_keys", null);
    try testing.expect(foreign_keys != null);
    try testing.expectEqual(@as(usize, 0), foreign_keys.?);

    if (build_options.in_memory) {
        {
            const journal_mode = try db.pragma([128:0]u8, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("memory", mem.spanZ(&journal_mode.?));
        }

        {
            const journal_mode = try db.pragmaAlloc([]const u8, &arena.allocator, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("memory", journal_mode.?);
        }
    } else {
        {
            const journal_mode = try db.pragma([128:0]u8, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("wal", mem.spanZ(&journal_mode.?));
        }

        {
            const journal_mode = try db.pragmaAlloc([]const u8, &arena.allocator, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("wal", journal_mode.?);
        }
    }
}

test "sqlite: last insert row id" {
    var db = try getTestDb();
    try createTestTables(&db);

    try db.exec("INSERT INTO user(name, age) VALUES(?, ?{u32})", .{}, .{
        .name = "test-user",
        .age = @as(u32, 400),
    });

    const id = db.getLastInsertRowID();
    try testing.expectEqual(@as(i64, 1), id);
}

test "sqlite: statement exec" {
    var db = try getTestDb();
    try addTestData(&db);

    // Test with a Blob struct
    {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{blob}, ?{u32})", .{}, .{
            .id = @as(usize, 200),
            .name = Blob{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }

    // Test with a Text struct
    {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{text}, ?{u32})", .{}, .{
            .id = @as(usize, 201),
            .name = Text{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }
}

test "sqlite: read a single user into a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT * FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var rows = try stmt.all(TestUser, &arena.allocator, .{}, .{
        .id = @as(usize, 20),
    });
    for (rows) |row| {
        try testing.expectEqual(test_users[0].id, row.id);
        try testing.expectEqualStrings(test_users[0].name, row.name);
        try testing.expectEqual(test_users[0].age, row.age);
    }

    // Read a row with db.one()
    {
        var row = try db.one(
            struct {
                name: [128:0]u8,
                id: usize,
                age: usize,
            },
            "SELECT name, id, age FROM user WHERE id = ?{usize}",
            .{},
            .{@as(usize, 20)},
        );
        try testing.expect(row != null);

        const exp = test_users[0];
        try testing.expectEqual(exp.id, row.?.id);
        try testing.expectEqualStrings(exp.name, mem.spanZ(&row.?.name));
        try testing.expectEqual(exp.age, row.?.age);
    }

    // Read a row with db.oneAlloc()
    {
        var row = try db.oneAlloc(
            struct {
                name: Text,
                id: usize,
                age: usize,
            },
            &arena.allocator,
            "SELECT name, id, age FROM user WHERE id = ?{usize}",
            .{},
            .{@as(usize, 20)},
        );
        try testing.expect(row != null);

        const exp = test_users[0];
        try testing.expectEqual(exp.id, row.?.id);
        try testing.expectEqualStrings(exp.name, row.?.name.data);
        try testing.expectEqual(exp.age, row.?.age);
    }
}

test "sqlite: read all users into a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT * FROM user");
    defer stmt.deinit();

    var rows = try stmt.all(TestUser, &arena.allocator, .{}, .{});
    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row, i| {
        const exp = test_users[i];
        try testing.expectEqual(exp.id, row.id);
        try testing.expectEqualStrings(exp.name, row.name);
        try testing.expectEqual(exp.age, row.age);
        try testing.expectEqual(exp.weight, row.weight);
    }
}

test "sqlite: read in an anonymous struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT name, id, name, age, id, weight FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var row = try stmt.oneAlloc(
        struct {
            name: []const u8,
            id: usize,
            name_2: [200:0xAD]u8,
            age: usize,
            is_id: bool,
            weight: f64,
        },
        &arena.allocator,
        .{},
        .{ .id = @as(usize, 20) },
    );
    try testing.expect(row != null);

    const exp = test_users[0];
    try testing.expectEqual(exp.id, row.?.id);
    try testing.expectEqualStrings(exp.name, row.?.name);
    try testing.expectEqualStrings(exp.name, mem.spanZ(&row.?.name_2));
    try testing.expectEqual(exp.age, row.?.age);
    try testing.expect(row.?.is_id);
    try testing.expectEqual(exp.weight, @floatCast(f32, row.?.weight));
}

test "sqlite: read in a Text struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT name, id, age FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var row = try stmt.oneAlloc(
        struct {
            name: Text,
            id: usize,
            age: usize,
        },
        &arena.allocator,
        .{},
        .{@as(usize, 20)},
    );
    try testing.expect(row != null);

    const exp = test_users[0];
    try testing.expectEqual(exp.id, row.?.id);
    try testing.expectEqualStrings(exp.name, row.?.name.data);
    try testing.expectEqual(exp.age, row.?.age);
}

test "sqlite: read a single text value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    const types = &[_]type{
        // Slices
        []const u8,
        []u8,
        [:0]const u8,
        [:0]u8,
        [:0xAD]const u8,
        [:0xAD]u8,
        // Array
        [8:0]u8,
        [8:0xAD]u8,
        // Specific text or blob
        Text,
        Blob,
    };

    inline for (types) |typ| {
        const query = "SELECT name FROM user WHERE id = ?{usize}";

        var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
        defer stmt.deinit();

        const name = try stmt.oneAlloc(typ, &arena.allocator, .{}, .{
            .id = @as(usize, 20),
        });
        try testing.expect(name != null);
        switch (typ) {
            Text, Blob => {
                try testing.expectEqualStrings("Vincent", name.?.data);
            },
            else => {
                const span = blk: {
                    const type_info = @typeInfo(typ);
                    break :blk switch (type_info) {
                        .Pointer => name.?,
                        .Array => mem.spanZ(&(name.?)),
                        else => @compileError("invalid type " ++ @typeName(typ)),
                    };
                };

                try testing.expectEqualStrings("Vincent", span);
            },
        }
    }
}

test "sqlite: read a single integer value" {
    var db = try getTestDb();
    try addTestData(&db);

    const types = &[_]type{
        u8,
        u16,
        u32,
        u64,
        u128,
        usize,
        f16,
        f32,
        f64,
        f128,
    };

    inline for (types) |typ| {
        const query = "SELECT age FROM user WHERE id = ?{usize}";

        var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
        defer stmt.deinit();

        var age = try stmt.one(typ, .{}, .{
            .id = @as(usize, 20),
        });
        try testing.expect(age != null);

        try testing.expectEqual(@as(typ, 33), age.?);
    }
}

test "sqlite: read a single value into an enum backed by an integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try createTestTables(&db);

    try db.exec("INSERT INTO user(id, age) VALUES(?{usize}, ?{usize})", .{}, .{
        .id = @as(usize, 10),
        .age = @as(usize, 0),
    });

    const query = "SELECT age FROM user WHERE id = ?{usize}";

    const IntColor = enum {
        violet,

        pub const BaseType = u1;
    };

    // Use one
    {
        var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
        defer stmt.deinit();

        const b = try stmt.one(IntColor, .{}, .{
            .id = @as(usize, 10),
        });
        try testing.expect(b != null);
        try testing.expectEqual(IntColor.violet, b.?);
    }

    // Use oneAlloc
    {
        var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
        defer stmt.deinit();

        const b = try stmt.oneAlloc(IntColor, &arena.allocator, .{}, .{
            .id = @as(usize, 10),
        });
        try testing.expect(b != null);
        try testing.expectEqual(IntColor.violet, b.?);
    }
}

test "sqlite: read a single value into an enum backed by a string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try createTestTables(&db);

    try db.exec("INSERT INTO user(id, favorite_color) VALUES(?{usize}, ?{[]const u8})", .{}, .{
        .id = @as(usize, 10),
        .age = @as([]const u8, "violet"),
    });

    const query = "SELECT favorite_color FROM user WHERE id = ?{usize}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.oneAlloc(TestUser.Color, &arena.allocator, .{}, .{
        .id = @as(usize, 10),
    });
    try testing.expect(b != null);
    try testing.expectEqual(TestUser.Color.violet, b.?);
}

test "sqlite: read a single value into void" {
    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT age FROM user WHERE id = ?{usize}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    _ = try stmt.one(void, .{}, .{
        .id = @as(usize, 20),
    });
}

test "sqlite: read a single value into bool" {
    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT id FROM user WHERE id = ?{usize}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{
        .id = @as(usize, 20),
    });
    try testing.expect(b != null);
    try testing.expect(b.?);
}

test "sqlite: insert bool and bind bool" {
    var db = try getTestDb();
    try addTestData(&db);

    try db.exec("INSERT INTO article(id, author_id, is_published) VALUES(?{usize}, ?{usize}, ?{bool})", .{}, .{
        .id = @as(usize, 1),
        .author_id = @as(usize, 20),
        .is_published = true,
    });

    const query = "SELECT id FROM article WHERE is_published = ?{bool}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{
        .is_published = true,
    });
    try testing.expect(b != null);
    try testing.expect(b.?);
}

test "sqlite: bind string literal" {
    var db = try getTestDb();
    try addTestData(&db);

    try db.exec("INSERT INTO article(id, data) VALUES(?, ?)", .{}, .{
        @as(usize, 10),
        "foobar",
    });

    const query = "SELECT id FROM article WHERE data = ?";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(usize, .{}, .{"foobar"});
    try testing.expect(b != null);
    try testing.expectEqual(@as(usize, 10), b.?);
}

test "sqlite: bind pointer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT name FROM user WHERE id = ?";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    for (test_users) |test_user, i| {
        stmt.reset();

        const name = try stmt.oneAlloc([]const u8, &arena.allocator, .{}, .{&test_user.id});
        try testing.expect(name != null);
        try testing.expectEqualStrings(test_users[i].name, name.?);
    }
}

test "sqlite: read pointers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT id, name, age, weight FROM user";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const rows = try stmt.all(
        struct {
            id: *usize,
            name: *[]const u8,
            age: *u32,
            weight: *f32,
        },
        &arena.allocator,
        .{},
        .{},
    );

    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row, i| {
        const exp = test_users[i];
        try testing.expectEqual(exp.id, row.id.*);
        try testing.expectEqualStrings(exp.name, row.name.*);
        try testing.expectEqual(exp.age, row.age.*);
        try testing.expectEqual(exp.weight, row.weight.*);
    }
}

test "sqlite: optional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{}, .{ 1, null, true });

    var stmt = try db.prepare("SELECT data, is_published FROM article");
    defer stmt.deinit();

    const row = try stmt.one(
        struct {
            data: ?[128:0]u8,
            is_published: ?bool,
        },
        .{},
        .{},
    );

    try testing.expect(row != null);
    try testing.expect(row.?.data == null);
    try testing.expectEqual(true, row.?.is_published.?);
}

test "sqlite: statement reset" {
    var db = try getTestDb();
    try addTestData(&db);

    // Add data

    var stmt = try db.prepare("INSERT INTO user(name, id, age, weight, favorite_color) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32}, ?{[]const u8})");
    defer stmt.deinit();

    const users = &[_]TestUser{
        .{ .id = 200, .name = "Vincent", .age = 33, .weight = 10.0, .favorite_color = .violet },
        .{ .id = 400, .name = "Julien", .age = 35, .weight = 12.0, .favorite_color = .green },
        .{ .id = 600, .name = "José", .age = 40, .weight = 14.0, .favorite_color = .indigo },
    };

    for (users) |user| {
        stmt.reset();
        try stmt.exec(.{}, user);

        const rows_inserted = db.rowsAffected();
        try testing.expectEqual(@as(usize, 1), rows_inserted);
    }
}

test "sqlite: statement iterator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var db = try getTestDb();
    try addTestData(&db);

    // Cleanup first
    try db.exec("DELETE FROM user", .{}, .{});

    // Add data
    var stmt = try db.prepare("INSERT INTO user(name, id, age, weight, favorite_color) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32}, ?{[]const u8})");
    defer stmt.deinit();

    var expected_rows = std.ArrayList(TestUser).init(allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "Vincent {d}", .{i});
        const user = TestUser{ .id = i, .name = name, .age = i + 200, .weight = @intToFloat(f32, i + 200), .favorite_color = .indigo };

        try expected_rows.append(user);

        stmt.reset();
        try stmt.exec(.{}, user);

        const rows_inserted = db.rowsAffected();
        try testing.expectEqual(@as(usize, 1), rows_inserted);
    }

    // Get data with a non-allocating iterator.
    {
        var stmt2 = try db.prepare("SELECT name, age FROM user");
        defer stmt2.deinit();

        const RowType = struct {
            name: [128:0]u8,
            age: usize,
        };

        var iter = try stmt2.iterator(RowType, .{});

        var rows = std.ArrayList(RowType).init(allocator);
        while (try iter.next(.{})) |row| {
            try rows.append(row);
        }

        // Check the data
        try testing.expectEqual(expected_rows.items.len, rows.items.len);

        for (rows.items) |row, j| {
            const exp_row = expected_rows.items[j];
            try testing.expectEqualStrings(exp_row.name, mem.spanZ(&row.name));
            try testing.expectEqual(exp_row.age, row.age);
        }
    }

    // Get data with an iterator
    {
        var stmt2 = try db.prepare("SELECT name, age FROM user");
        defer stmt2.deinit();

        const RowType = struct {
            name: Text,
            age: usize,
        };

        var iter = try stmt2.iterator(RowType, .{});

        var rows = std.ArrayList(RowType).init(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| {
            try rows.append(row);
        }

        // Check the data
        try testing.expectEqual(expected_rows.items.len, rows.items.len);

        for (rows.items) |row, j| {
            const exp_row = expected_rows.items[j];
            try testing.expectEqualStrings(exp_row.name, row.name.data);
            try testing.expectEqual(exp_row.age, row.age);
        }
    }
}

test "sqlite: blob open, reopen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var db = try getTestDb();
    defer db.deinit();

    const blob_data1 = "\xDE\xAD\xBE\xEFabcdefghijklmnopqrstuvwxyz0123456789";
    const blob_data2 = "\xCA\xFE\xBA\xBEfoobar";

    // Insert two blobs with a set length
    try db.exec("CREATE TABLE test_blob(id integer primary key, data blob)", .{}, .{});

    try db.exec("INSERT INTO test_blob(data) VALUES(?)", .{}, .{
        .data = ZeroBlob{ .length = blob_data1.len * 2 },
    });
    const rowid1 = db.getLastInsertRowID();

    try db.exec("INSERT INTO test_blob(data) VALUES(?)", .{}, .{
        .data = ZeroBlob{ .length = blob_data2.len * 2 },
    });
    const rowid2 = db.getLastInsertRowID();

    // Open the blob in the first row
    var blob = try db.openBlob(.main, "test_blob", "data", rowid1, .{ .write = true });

    {
        // Write the first blob data
        var blob_writer = blob.writer();
        try blob_writer.writeAll(blob_data1);
        try blob_writer.writeAll(blob_data1);

        blob.reset();

        var blob_reader = blob.reader();
        const data = try blob_reader.readAllAlloc(allocator, 8192);

        try testing.expectEqualSlices(u8, blob_data1 ** 2, data);
    }

    // Reopen the blob in the second row
    try blob.reopen(rowid2);

    {
        // Write the second blob data
        var blob_writer = blob.writer();
        try blob_writer.writeAll(blob_data2);
        try blob_writer.writeAll(blob_data2);

        blob.reset();

        var blob_reader = blob.reader();
        const data = try blob_reader.readAllAlloc(allocator, 8192);

        try testing.expectEqualSlices(u8, blob_data2 ** 2, data);
    }

    try blob.close();
}

test "sqlite: failing open" {
    var diags: Diagnostics = undefined;

    const res = Db.init(.{
        .diags = &diags,
        .open_flags = .{},
        .mode = .{ .File = "/tmp/not_existing.db" },
    });
    try testing.expectError(error.SQLiteCantOpen, res);
    try testing.expectEqual(@as(usize, 14), diags.err.?.code);
    try testing.expectEqualStrings("unable to open database file", diags.err.?.message);
}

test "sqlite: failing prepare statement" {
    var db = try getTestDb();

    var diags: Diagnostics = undefined;

    const result = db.prepareWithDiags("SELECT id FROM foobar", .{ .diags = &diags });
    try testing.expectError(error.SQLiteError, result);

    const detailed_err = db.getDetailedError();
    try testing.expectEqual(@as(usize, 1), detailed_err.code);
    try testing.expectEqualStrings("no such table: foobar", detailed_err.message);
}

test "sqlite: diagnostics format" {
    const TestCase = struct {
        input: Diagnostics,
        exp: []const u8,
    };

    const testCases = &[_]TestCase{
        .{
            .input = .{},
            .exp = "my diagnostics: none",
        },
        .{
            .input = .{
                .message = "foobar",
            },
            .exp = "my diagnostics: foobar",
        },
        .{
            .input = .{
                .err = .{
                    .code = 20,
                    .message = "barbaz",
                },
            },
            .exp = "my diagnostics: {code: 20, message: barbaz}",
        },
        .{
            .input = .{
                .message = "foobar",
                .err = .{
                    .code = 20,
                    .message = "barbaz",
                },
            },
            .exp = "my diagnostics: {message: foobar, detailed error: {code: 20, message: barbaz}}",
        },
    };

    inline for (testCases) |tc| {
        var buf: [1024]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "my diagnostics: {s}", .{tc.input});

        try testing.expectEqualStrings(tc.exp, str);
    }
}

test "sqlite: exec with diags, failing statement" {
    var db = try getTestDb();

    var diags = Diagnostics{};

    const result = blk: {
        var stmt = try db.prepareWithDiags("ROLLBACK", .{ .diags = &diags });
        break :blk stmt.exec(.{ .diags = &diags }, .{});
    };

    try testing.expectError(error.SQLiteError, result);
    try testing.expect(diags.err != null);
    try testing.expectEqualStrings("cannot rollback - no transaction is active", diags.err.?.message);

    const detailed_err = db.getDetailedError();
    try testing.expectEqual(@as(usize, 1), detailed_err.code);
    try testing.expectEqualStrings("cannot rollback - no transaction is active", detailed_err.message);
}

fn getTestDb() !Db {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var mode = dbMode(&fba.allocator);

    return try Db.init(.{
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .mode = mode,
    });
}

fn tmpDbPath(allocator: mem.Allocator) ![:0]const u8 {
    const tmp_dir = testing.tmpDir(.{});

    const path = try std.fs.path.join(allocator, &[_][]const u8{
        "zig-cache",
        "tmp",
        &tmp_dir.sub_path,
        "zig-sqlite.db",
    });
    defer allocator.free(path);

    return allocator.dupeZ(u8, path);
}

fn dbMode(allocator: mem.Allocator) Db.Mode {
    return if (build_options.in_memory) blk: {
        break :blk .{ .Memory = {} };
    } else blk: {
        if (build_options.dbfile) |dbfile| {
            return .{ .File = allocator.dupeZ(u8, dbfile) catch unreachable };
        }

        const path = tmpDbPath(allocator) catch unreachable;

        std.fs.cwd().deleteFile(path) catch {};
        break :blk .{ .File = path };
    };
}
