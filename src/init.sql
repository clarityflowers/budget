PRAGMA foreign_keys = 1;
CREATE TABLE accounts(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  account_type TEXT CHECK(
    account_type='checking' or 
    account_type='savings' or 
    account_type='credit' or 
    account_type='cash' or 
    account_type='investment' or 
    account_type='other'
  )     
);
CREATE TABLE payees(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE );
CREATE TABLE payee_matches(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  payee_id INTEGER,
  transfer_id INTEGER,
  match TEXT NOT NULL UNIQUE,
  pattern TEXT,
  FOREIGN KEY(payee_id) REFERENCES payees(id),
  FOREIGN KEY(transfer_id) REFERENCES accounts(id),
  CONSTRAINT payee_matches_payee_xor_transfer CHECK(
      (payee_id IS NULL) <> (transfer_id IS NULL)
  )
);
CREATE TABLE category_groups(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE );
CREATE TABLE categories(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_group_id INTEGER,
  name TEXT NOT NULL,
  FOREIGN KEY(category_group_id) REFERENCES category_groups(id)
);
CREATE UNIQUE INDEX categories_unique on categories(COALESCE(category_group_id, 0), name);
CREATE TABLE category_matches(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  payee_id INTEGER NOT NULL,
  category_id INTEGER,
  amount INTEGER DEFAULT NULL,
  note TEXT DEFAULT NULL,
  note_pattern TEXT DEFAULT NULL,
  FOREIGN KEY(payee_id)       REFERENCES payees(id),
  FOREIGN KEY(category_id)    REFERENCES categories(id)
);
CREATE UNIQUE INDEX category_matches_unique on category_matches(payee_id, ifnull(amount, 0), ifnull(note, ''), ifnull(note_pattern, ''));
CREATE TABLE import_rules(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL UNIQUE,
  file_type TEXT NOT NULL CHECK(file_type='csv' or file_type='tsv'),
  date_column TEXT NOT NULL,
  date_format TEXT NOT NULL,
  income_column TEXT NOT NULL,
  expenses_column TEXT NOT_NULL,
  payee_columns TEXT,
  memo_columns TEXT,
  id_columns TEXT,
  FOREIGN KEY(account_id) REFERENCES accounts(id)
);
CREATE TABLE transactions(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL,
  date TEXT NOT NULL,
  amount INTEGER NOT NULL,
  payee_id INTEGER NOT NULL,
  category_id INTEGER,
  note TEXT NOT NULL,
  bank_id INTEGER,
  split_from INTEGER,
  FOREIGN KEY(account_id)     REFERENCES accounts(id),
  FOREIGN KEY(payee_id)       REFERENCES payees(id),
  FOREIGN KEY(category_id)    REFERENCES categories(id),
  FOREIGN KEY(split_from)    REFERENCES transactions(id)
);
CREATE TABLE transfers(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_account_id INTEGER NOT NULL,
  to_account_id INTEGER NOT NULL,
  date TEXT NOT NULL,
  amount INTEGER NOT NULL,
  note TEXT NOT NULL,
  bank_id INTEGER,
  split_from INTEGER,
  FOREIGN KEY(from_account_id) REFERENCES accounts(id),
  FOREIGN KEY(to_account_id) REFERENCES accounts(id),
  FOREIGN KEY(split_from) REFERENCES transactions(id)
);
CREATE TABLE monthly_budgets(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  month TEXT NOT NULL,
  amount INTEGER NOT NULL,
  category_id INTEGER NOT NULL,
  FOREIGN KEY(category_id)  REFERENCES categories(id)
);
CREATE UNIQUE INDEX monthly_budgets_unique on monthly_budgets(month, category_id);
CREATE TABLE off_budget_accounts(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  payee_id INTEGER NOT NULL UNIQUE,
  FOREIGN KEY(payee_id)  REFERENCES payees(id)
);
CREATE TABLE off_budget_transactions(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id INTEGER NOT NULL,
  date TEXT NOT NULL,
  amount INTEGER NOT NULL,
  payee_id INTEGER NOT NULL,
  note TEXT NOT NULL,
  bank_id INTEGER,
  FOREIGN KEY(account_id) REFERENCES off_budget_accounts(id),
  FOREIGN KEY(payee_id) REFERENCES payees(id)
);
