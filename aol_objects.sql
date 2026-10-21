-- Usage: @aol_discover.sql <since YYYY-MM-DD> <output file>
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0 LINESIZE 1000 TRIMSPOOL ON HEADING OFF FEEDBACK OFF
SET VERIFY OFF ECHO OFF TERMOUT OFF TAB OFF

DEFINE since = '&1'
SPOOL &2

SELECT obj_type || '|' || NVL(app,'-') || '|' || obj_key
FROM (
  SELECT 'PROGRAM' obj_type, a.application_short_name app, p.concurrent_program_name obj_key
    FROM fnd_concurrent_programs p JOIN fnd_application a ON a.application_id = p.application_id
   WHERE p.concurrent_program_name LIKE 'XX%' AND p.last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'VALUE_SET', NULL, flex_value_set_name
    FROM fnd_flex_value_sets
   WHERE flex_value_set_name LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'LOOKUP', a.application_short_name, l.lookup_type
    FROM fnd_lookup_types l JOIN fnd_application a ON a.application_id = l.application_id
   WHERE l.lookup_type LIKE 'XX%' AND l.last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'FUNCTION', NULL, function_name
    FROM fnd_form_functions
   WHERE function_name LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'MENU', NULL, menu_name
    FROM fnd_menus
   WHERE menu_name LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'RESPONSIBILITY', NULL, responsibility_key
    FROM fnd_responsibility
   WHERE responsibility_key LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'MESSAGE', a.application_short_name, m.message_name
    FROM fnd_new_messages m JOIN fnd_application a ON a.application_id = m.application_id
   WHERE m.message_name LIKE 'XX%' AND m.last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'REQUEST_GROUP', a.application_short_name, g.request_group_name
    FROM fnd_request_groups g JOIN fnd_application a ON a.application_id = g.application_id
   WHERE g.request_group_name LIKE 'XX%' AND g.last_update_date > TO_DATE('&since','YYYY-MM-DD')
)
ORDER BY DECODE(obj_type,'VALUE_SET',10,'LOOKUP',20,'MESSAGE',30,'PROGRAM',50,
                'REQUEST_GROUP',60,'FUNCTION',70,'MENU',80,'RESPONSIBILITY',90), obj_key;

SPOOL OFF
EXIT