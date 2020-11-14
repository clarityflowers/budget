const sqlite = @import("sqlite-zig/src/sqlite.zig");
const std = @import("std");
const log = std.log.scoped(.budget);

// SQLite doesn't enforce foreign constrains unless you tell it to
const SQL_ENFORCE_FOREIGN_KEYS =
    \\PRAGMA foreign_keys = 1;
;

const SQL_CREATE_ACCOUNTS =
    \\CREATE TABLE accounts(
    \\  id              INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  name            TEXT    NOT NULL    UNIQUE,
    \\  is_budget       INTEGER NOT NULL    CHECK(is_budget=0 OR is_budget=1),
    \\  account_type    TEXT    NOT NULL    CHECK(account_type='checking' or account_type='savings' or account_type='credit')     
    \\);
;
const SQL_CREATE_PAYEES =
    \\CREATE TABLE payees(
    \\  id      INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  name    TEXT    NOT NULL    UNIQUE
    \\);
;
const SQL_CREATE_PAYEE_MATCHES =
    \\CREATE TABLE payee_matches(
    \\  id          INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  payee_id    INTEGER,
    \\  transfer_id INTEGER,
    \\  match       TEXT    NOT NULL    UNIQUE,
    \\  pattern     TEXT,
    \\  FOREIGN KEY(payee_id) REFERENCES payees(id),
    \\  FOREIGN KEY(transfer_id) REFERENCES accounts(id),
    \\  CONSTRAINT payee_matches_payee_xor_transfer CHECK(
    \\      (payee_id IS NULL) <> (transfer_id IS NULL)
    \\  )
    \\);
;

const SQL_CREATE_CATEGORY_GROUPS =
    \\CREATE TABLE category_groups(
    \\  id      INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  name    TEXT    NOT NULL    UNIQUE
    \\);
;
const SQL_CREATE_CATEGORIES =
    \\CREATE TABLE categories(
    \\  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  category_group_id   INTEGER NOT NULL,
    \\  name                TEXT    NOT NULL,
    \\  FOREIGN KEY(category_group_id) REFERENCES category_groups(id)
    \\);
    \\CREATE UNIQUE INDEX categories_unique on categories(category_group_id, name);
;
const SQL_CREATE_CATEGORY_MATCHES =
    \\CREATE TABLE category_matches(
    \\  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  payee_id            INTEGER NOT NULL,
    \\  category_id         INTEGER,
    \\  amount              INTEGER,
    \\  note                TEXT,
    \\  note_pattern        TEXT,
    \\  FOREIGN KEY(payee_id)       REFERENCES payees(id),
    \\  FOREIGN KEY(category_id)    REFERENCES categories(id)
    \\);
    \\CREATE UNIQUE INDEX category_matches_unique on category_matches(payee_id, amount, note, note_pattern);
;
const SQL_CREATE_IMPORT_RULES =
    \\CREATE TABLE import_rules(
    \\  id              INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  account_id      INTEGER NOT NULL    UNIQUE,
    \\  file_type       TEXT    NOT NULL    CHECK(file_type='csv' or file_type='tsv'),
    \\  date_column     TEXT    NOT NULL,
    \\  date_format     TEXT    NOT NULL,
    \\  income_column   TEXT    NOT NULL,
    \\  expenses_column TEXT    NOT_NULL,
    \\  payee_columns   TEXT,
    \\  memo_columns    TEXT,
    \\  id_columns      TEXT,
    \\  FOREIGN KEY(account_id) REFERENCES accounts(id)
    \\);
;
const SQL_CREATE_TRANSACTIONS =
    \\CREATE TABLE transactions(
    \\  id          INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  account_id  INTEGER NOT NULL,
    \\  date        INTEGER NOT NULL,
    \\  amount      INTEGER NOT NULL,
    \\  payee_id    INTEGER,
    \\  category_id INTEGER,
    \\  transfer_id INTEGER,
    \\  note        TEXT    NOT NULL,
    \\  bank_id     INTEGER NOT NULL,
    \\  reconciled  INTEGER NOT NULL    CHECK (reconciled=0 OR reconciled=1),
    \\  FOREIGN KEY(account_id)     REFERENCES accounts(id),
    \\  FOREIGN KEY(payee_id)       REFERENCES payees(id),
    \\  FOREIGN KEY(category_id)    REFERENCES categories(id),
    \\  FOREIGN KEY(transfer_id)    REFERENCES accounts(id),
    \\  CONSTRAINT transaction_is_transfer_xor_has_payee CHECK(
    \\      (transfer_id NOT NULL) <> (payee_id NOT NULL)
    \\  )
    \\);
;

pub fn init(db_filename: [:0]const u8) !void {
    const db_filename_str = db_filename[0 .. db_filename.len - 1];
    log.info("Initializing budget {}...", .{db_filename_str});
    const cwd = std.fs.cwd();
    if (cwd.accessZ(db_filename, .{})) {
        log.alert("Attempting to initialize a budget that already exists!", .{});
        return error.InvalidArguments;
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => |other_err| return other_err,
        }
    }

    var db = sqlite.Database.openWithOptions(db_filename, .{}) catch |err| {
        log.alert("The database file {x} couldn't be opened.", .{db_filename});
        return err;
    };
    defer db.close() catch unreachable;

    db.exec(SQL_ENFORCE_FOREIGN_KEYS) catch |err| {
        log.alert("Error while setting foreign key constraints: {}", .{db.errmsg()});
        return err;
    };
    db.exec(SQL_CREATE_PAYEES) catch |err| {
        log.alert("Error while creating payees table: {}", .{db.errmsg()});
        return err;
    };
    db.exec(SQL_CREATE_PAYEE_MATCHES) catch |err| {
        log.alert("Error while creating payee matches table: {}", .{db.errmsg()});
        return err;
    };
    db.exec(SQL_CREATE_CATEGORY_GROUPS) catch |err| {
        log.alert("Error while creating category_groups table: {}", .{db.errmsg()});
        return err;
    };
    db.exec(SQL_CREATE_ACCOUNTS) catch |err| {
        log.alert("Error while creating categories table: {}", .{db.errmsg()});
        return err;
    };
    db.exec(SQL_CREATE_CATEGORIES) catch |err| {
        log.alert("Error while creating categories table: {}", .{db.errmsg()});
        return err;
    };
    db.exec(SQL_CREATE_IMPORT_RULES) catch |err| {
        log.alert("Error while creating import_rules table: {}", .{db.errmsg()});
        return err;
    };
    db.exec(SQL_CREATE_TRANSACTIONS) catch |err| {
        log.alert("Error while creating transactions table: {}", .{db.errmsg()});
        return err;
    };
    log.info("All done! Your budget has been initialized at {}.", .{db_filename});
}
