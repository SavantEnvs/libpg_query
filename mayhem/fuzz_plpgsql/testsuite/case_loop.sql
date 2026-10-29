CREATE FUNCTION f(x int) RETURNS int AS $$
DECLARE
  i int := 0;
  msg text;
BEGIN
  CASE WHEN x > 10 THEN msg := 'big'; WHEN x > 5 THEN msg := 'mid'; ELSE msg := 'small'; END CASE;
  WHILE i < x LOOP
    i := i + 1;
    CONTINUE WHEN i % 2 = 0;
    EXIT WHEN i > 100;
  END LOOP;
  BEGIN
    PERFORM 1 / 0;
  EXCEPTION WHEN division_by_zero THEN
    RAISE NOTICE 'caught %', msg;
  END;
  RETURN i;
END;
$$ LANGUAGE plpgsql;
