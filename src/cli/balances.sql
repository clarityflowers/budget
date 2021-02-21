SELECT
  categories.id,
  category_groups.name, 
  categories.name,
  COALESCE(SUM(transactions.amount), 0) + COALESCE(SUM(category_budgets.amount), 0)
FROM categories
JOIN category_groups ON category_groups.id = categories.category_group_id
LEFT JOIN (
  select * from transactions
  WHERE transactions.date < '2021-01-01'
) as transactions ON transactions.category_id = categories.id
LEFT JOIN (
  select * from category_budgets
  WHERE category_budgets.month < '2021-01'
) as category_budgets ON category_budgets.category_id = categories.id
GROUP BY categories.id
ORDER BY category_groups.name, categories.name
