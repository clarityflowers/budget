SELECT 
  payee_id, 
  transfer_id, 
  CASE COALESCE(pattern,'')
    WHEN '' THEN 0
    WHEN 'starts_with' THEN 1
    WHEN 'ends_with' THEN 2
    WHEN 'contains' THEN 3
    ELSE null
  END AS sort_rank
FROM payee_matches
LEFT JOIN accounts on transfer_id = accounts.id
WHERE 
  sort_rank IS NOT NULL AND
  (accounts.id IS NULL OR accounts.id <> ?2) AND
  ?1 LIKE CASE COALESCE(pattern, '')
    WHEN '' THEN match
    WHEN 'starts_with' THEN match || '%'
    WHEN 'ends_with' THEN '%' || match
    WHEN 'contains' THEN '%' || match || '%'
    ELSE ''
  END

UNION

SELECT
  id AS payee_id,
  NULL AS transfer_id,
  4 AS sort_rank
FROM payees
WHERE name = ?1

UNION

SELECT
  NULL as payee_id,
  id as transfer_id,
  5 AS sort_rank
FROM accounts
WHERE 
  'Transfer to ' || name = ?1 AND 
  id <> ?2

ORDER BY sort_rank
LIMIT 1;
