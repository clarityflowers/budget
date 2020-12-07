SELECT 
  category_id, 
  CASE COALESCE(note_pattern,'')
    WHEN 'starts_with' THEN 1
    WHEN 'ends_with' THEN 2
    WHEN 'contains' THEN 3
    ELSE 0
  END AS sort_rank,
  id
FROM category_matches
WHERE 
  payee_id = ?2 AND (
    note IS NULL OR
    ?1 LIKE CASE COALESCE(note_pattern, '')
      WHEN 'starts_with' THEN note || '%'
      WHEN 'ends_with' THEN '%' || note
      WHEN 'contains' THEN '%' || note || '%'
      ELSE note
    END
  ) AND
  (amount IS NULL OR amount = ?3)
ORDER BY sort_rank
LIMIT 1;
