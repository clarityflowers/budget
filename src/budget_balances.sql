SELECT
  category_id,
  month,
  SUM(budget) as budgets,
  SUM(trans) as transactions,
  SUM(budget + trans) as net
FROM (
  SELECT amount as budget, 0 as trans, category_id, month from monthly_budgets
  UNION ALL
  SELECT 0 as budget, amount as trans, category_id, SUBSTR(date, 0, 8) AS month from transactions
  WHERE category_id IS NOT NULL
)
GROUP BY category_id, month
