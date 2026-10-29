CREATE FUNCTION get_available_flightid(date) RETURNS SETOF integer AS
$BODY$
BEGIN
    RETURN QUERY SELECT flightid FROM flight WHERE flightdate >= $1 AND flightdate < ($1 + 1);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No flight at %.', $1;
    END IF;
    RETURN;
END
$BODY$
LANGUAGE plpgsql;
