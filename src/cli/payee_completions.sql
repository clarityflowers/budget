SELECT 
  name, 
  transfer_id, 
  payee_id,
  CASE
    WHEN name LIKE ?1 THEN 0
    WHEN name LIKE (?1 || '%') THEN 1
    WHEN name LIKE ('Transfer to ' || ?1 || '%') THEN 2
    ELSE NULL
  END AS sort_rank
FROM (
  SELECT 
    'Transfer to ' || accounts.name AS name, 
    accounts.id AS transfer_id, 
    NULL AS payee_id 
  FROM accounts 
  UNION 
  SELECT 
    payees.name AS name, 
    null AS transfer_id, 
    payees.id AS payee_id 
  FROM payees
) 
WHERE sort_rank IS NOT NULL
ORDER BY sort_rank, name
LIMIT 5;