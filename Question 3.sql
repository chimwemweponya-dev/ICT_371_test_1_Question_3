-- Q3(a) Tables & Seed Data
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0)
);

-- Q3(b) Function: fn_loan_fine
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on      DATE;
    v_returned_on DATE;
    v_eff_date    DATE;
    v_days_late   INTEGER;
BEGIN
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_eff_date := CASE
        WHEN v_returned_on IS NOT NULL THEN LEAST(p_as_of, v_returned_on)
        ELSE p_as_of
    END;

    v_days_late := GREATEST(0, (v_eff_date - v_due_on));
    RETURN ROUND(v_days_late * 2.00, 2);
END;
$$;

-- Q3(c) Procedure: pr_return_loan
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_final_fine  NUMERIC(10, 2);
BEGIN
    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on IS NULL OR p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date % cannot be before borrowed_on %', p_returned_on, v_borrowed_on;
    END IF;

    UPDATE loans
    SET returned_on = p_returned_on
    WHERE loan_id = p_loan_id;

    v_final_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET fine_amount = v_final_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- Q3(d) Trigger: AFTER UPDATE on loans.returned_on -> loan_audit
CREATE OR REPLACE FUNCTION fn_trg_loans_return_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_trg_loans_return_audit();

-- Seed 3 books & 6 loans (open overdue, on-time active, returned)
INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Designing Data-Intensive Applications'),
    ('Clean Architecture');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Kelvin Tembo', CURRENT_DATE - 15, CURRENT_DATE - 5, NULL, 0.00), -- Open overdue
    (2, 'Natasha Zulu', CURRENT_DATE - 3, CURRENT_DATE + 7, NULL, 0.00),  -- On-time active
    (3, 'Bwalya Lungu', CURRENT_DATE - 10, CURRENT_DATE - 3, CURRENT_DATE - 3, 0.00), -- Returned on due date
    (1, 'Chipo Sakala', CURRENT_DATE - 14, CURRENT_DATE - 6, CURRENT_DATE - 2, 8.00), -- Returned late
    (2, 'Mwamba Kunda', CURRENT_DATE - 20, CURRENT_DATE - 10, NULL, 0.00), -- Open overdue
    (3, 'Lombe Chileshe', CURRENT_DATE - 2, CURRENT_DATE + 12, NULL, 0.00); -- On-time active

-- Q3(e) View: v_overdue_loans
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- Q3(f) Partial Index & EXPLAIN
-- Only unreturned loans (returned_on IS NULL) are indexed, keeping index small & fast
CREATE INDEX idx_loans_unreturned_book ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
-- Expected plan node: Index Scan using idx_loans_unreturned_book on loans

-- Q3(g) Procedure & Scheduled Job (00:10 daily for CURRENT_DATE)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_fine  NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*),
        COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    INTO v_count, v_fine
    FROM loans
    WHERE returned_on IS NULL
      AND due_on < p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_fine)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule(
    'refresh_overdue_summary',
    '10 0 * * *',
    $$CALL pr_refresh_overdue((CURRENT_TIMESTAMP AT TIME ZONE 'Africa/Lusaka')::date);$$
);