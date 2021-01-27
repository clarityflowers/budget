PRAGMA foreign_keys = 1;
CREATE TABLE accounts(
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  name            TEXT    NOT NULL    UNIQUE,
  is_budget       INTEGER NOT NULL    CHECK(is_budget=0 OR is_budget=1),
  account_type    TEXT    NOT NULL    CHECK(account_type='checking' or account_type='savings' or account_type='credit')     
);
CREATE TABLE payees(
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  name    TEXT    NOT NULL    UNIQUE
);
CREATE TABLE payee_matches(
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  payee_id    INTEGER,
  transfer_id INTEGER,
  match       TEXT    NOT NULL    UNIQUE,
  pattern     TEXT,
  FOREIGN KEY(payee_id) REFERENCES payees(id),
  FOREIGN KEY(transfer_id) REFERENCES accounts(id),
  CONSTRAINT payee_matches_payee_xor_transfer CHECK(
      (payee_id IS NULL) <> (transfer_id IS NULL)
  )
);
CREATE TABLE category_groups(
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  name    TEXT    NOT NULL    UNIQUE
);
CREATE TABLE categories(
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  category_group_id   INTEGER NOT NULL,
  name                TEXT    NOT NULL,
  FOREIGN KEY(category_group_id) REFERENCES category_groups(id)
);
CREATE UNIQUE INDEX categories_unique on categories(category_group_id, name);
CREATE TABLE category_matches(
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  payee_id            INTEGER NOT NULL,
  category_id         INTEGER,
  amount              INTEGER DEFAULT NULL,
  note                TEXT    DEFAULT NULL,
  note_pattern        TEXT    DEFAULT NULL,
  FOREIGN KEY(payee_id)       REFERENCES payees(id),
  FOREIGN KEY(category_id)    REFERENCES categories(id)
);
CREATE UNIQUE INDEX category_matches_unique on category_matches(payee_id, ifnull(amount, 0), ifnull(note, ''), ifnull(note_pattern, ''));
CREATE TABLE import_rules(
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id      INTEGER NOT NULL    UNIQUE,
  file_type       TEXT    NOT NULL    CHECK(file_type='csv' or file_type='tsv'),
  date_column     TEXT    NOT NULL,
  date_format     TEXT    NOT NULL,
  income_column   TEXT    NOT NULL,
  expenses_column TEXT    NOT_NULL,
  payee_columns   TEXT,
  memo_columns    TEXT,
  id_columns      TEXT,
  FOREIGN KEY(account_id) REFERENCES accounts(id)
);
CREATE TABLE transactions(
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id  INTEGER NOT NULL,
  date        INTEGER NOT NULL,
  amount      INTEGER NOT NULL,
  payee_id    INTEGER,
  category_id INTEGER,
  transfer_id INTEGER,
  note        TEXT    NOT NULL,
  bank_id     INTEGER NOT NULL,
  reconciled  INTEGER NOT NULL    CHECK (reconciled=0 OR reconciled=1)  DEFAULT 0,
  FOREIGN KEY(account_id)     REFERENCES accounts(id),
  FOREIGN KEY(payee_id)       REFERENCES payees(id),
  FOREIGN KEY(category_id)    REFERENCES categories(id),
  FOREIGN KEY(transfer_id)    REFERENCES accounts(id),
  CONSTRAINT transaction_is_transfer_xor_has_payee CHECK(
      (transfer_id NOT NULL) <> (payee_id NOT NULL)
  )
  CONSTRAINT transaction_transfer_has_no_category CHECK(
      (transfer_id NULL) OR (category_id NULL)
  )
);