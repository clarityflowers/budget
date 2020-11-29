SELECT
  group_Id,
  category_id,
  group_name || name as completion,
  sort_rank,
  CASE COALESCE(sort_rank, -1)
    WHEN 0 THEN group_name || name
    WHEN 1 THEN group_name
    WHEN 2 THEN group_name
    WHEN 5 THEN group_name
    ELSE ''
  END AS match
FROM (
  SELECT 
    group_id,
    category_id,
    name,
    group_name,
    CASE
      WHEN (group_name || name) LIKE ?1 THEN 0
      WHEN name LIKE ?1 THEN 1
      WHEN (?1 LIKE group_name || "%") AND ((group_name || name) LIKE (?1 || '%')) THEN 2
      WHEN name LIKE (?1 || '%') THEN 5
      ELSE NULL
    END AS sort_rank
  FROM (
    SELECT
      category_groups.id AS group_id,
      categories.id AS category_id,
      category_groups.name || ': ' AS group_name,
      categories.name AS name
    FROM categories
    CROSS JOIN category_groups

    UNION

    SELECT 
      NULL AS group_id, 
      NULL AS category_id, 
      '' as group_name, 
      'Income' AS name
  )
)
WHERE sort_rank IS NOT NULL

UNION

SELECT
  id AS group_id,
  NULL AS category_id,
  name || ': ' AS name,
  CASE
    WHEN ?1 LIKE (name || ': %') THEN 3
    WHEN (name || ': ') LIKE (?1 || '%') THEN 4
    ELSE NULL
  END AS sort_rank,
  name || ': ' AS match
FROM category_groups
WHERE sort_rank IS NOT NULL

ORDER BY sort_rank, name;