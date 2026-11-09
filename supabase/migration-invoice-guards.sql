-- ============================================================
-- MIGRATION 4: the database, not the caller, decides a document's amounts
--              and refuses to put the same sale on two documents of a kind
-- Run this in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to run more than once. Run AFTER migration-invoices.sql,
-- migration-invoice-payments.sql, migration-receipt-doctype.sql and
-- migration-receipt-settle.sql.
--
-- Why:
-- 1. issue_invoice / issue_receipt used to store whatever base / vat / grand
--    the caller sent. The web app computes them correctly, but any other
--    caller (an AI tool, a script, a buggy screen) could stamp a real running
--    number onto a wrong total. Now the amounts are recomputed here from the
--    sales rows in p_sale_ids; p_base / p_vat / p_grand are still accepted so
--    the web app keeps working unchanged, but they are IGNORED.
-- 2. Nothing stopped one sale from landing on two documents of the same kind.
--    This already happened once: REC6909-0015 and REC6909-0016 were issued 5
--    seconds apart for the same ฿138 sale (a double click). Now a sale may sit
--    on at most one live (status = 'issued') document per kind, where
--    ใบกำกับภาษี/ใบเสร็จ (taxreceipt, IV) and ใบส่งสินค้า/ใบกำกับภาษี
--    (delivery, DN) count as ONE kind — both are tax invoices, and a sale may
--    only be taxed once. Different kinds may still share sales, which the
--    normal workflow relies on: BL + DN issued as a pair, then a REC.
--    Cancel the old document first if it really has to be re-issued.
--
-- VAT rule is unchanged from the web app: 7% on every type except 'cash'
-- (ใบเสร็จรับเงิน/บิลเงินสด), now rounded to satang. All 343 documents issued
-- before this migration already match this rule to within 1 satang.
--
-- p_items (the printed line items) is still taken from the caller: product
-- labels live in the app, not the database. Reprints are rebuilt from the
-- sales rows anyway, so the stored items are display-only.
-- ============================================================

-- Locks the sales a new document will cover, checks them, and returns the
-- amounts. Called only from the two issue_* functions below (which run as the
-- table owner); not callable from the app directly.
create or replace function doc_check_and_amounts(
  p_doc_type    text,
  p_customer_id uuid,
  p_sale_ids    uuid[],
  out o_base    numeric,
  out o_vat     numeric,
  out o_grand   numeric
)
language plpgsql set search_path = public as $$
declare
  v_ids   uuid[] := coalesce(p_sale_ids, '{}');
  v_want  int;
  v_found int;
  v_other int;
  v_taken text;
begin
  if cardinality(v_ids) = 0 then
    raise exception 'ไม่มีรายการขายให้ออกเอกสาร';
  end if;

  select count(distinct x) into v_want from unnest(v_ids) as x;
  if v_want <> cardinality(v_ids) then
    raise exception 'รายการขายซ้ำกันในคำขอเดียว';
  end if;

  -- Row-lock the sales (in id order, so two callers can't deadlock). A second
  -- request for any of the same sales waits here until the first commits, and
  -- its conflict check below then sees the first document.
  perform 1 from sales where id = any(v_ids) order by id for update;

  select count(*),
         count(*) filter (where customer_id is distinct from p_customer_id),
         coalesce(sum(total), 0)
    into v_found, v_other, o_base
    from sales where id = any(v_ids);

  if v_found <> v_want then
    raise exception 'ไม่พบรายการขาย % รายการ (อาจถูกลบไปแล้ว) — รีเฟรชหน้าแล้วลองใหม่', v_want - v_found;
  end if;
  if v_other > 0 then
    raise exception 'มีรายการขาย % รายการที่ไม่ใช่ของลูกค้ารายนี้', v_other;
  end if;

  select string_agg(distinct doc_no, ', ' order by doc_no) into v_taken
    from invoices
   where status = 'issued'
     and sale_ids && v_ids
     and (doc_type = p_doc_type
          or (p_doc_type in ('taxreceipt', 'delivery')
              and doc_type in ('taxreceipt', 'delivery')));
  if v_taken is not null then
    raise exception 'รายการขายนี้อยู่ในเอกสาร % ที่ออกเลขแล้ว — ถ้าต้องออกใหม่ ให้ยกเลิกใบเดิมในทะเบียนเอกสารก่อน', v_taken;
  end if;

  o_vat   := case when p_doc_type = 'cash' then 0 else round(o_base * 0.07, 2) end;
  o_grand := o_base + o_vat;
end $$;

revoke all on function doc_check_and_amounts(text, uuid, uuid[]) from public, anon, authenticated;

-- Same signature as migration-invoice-payments.sql, so the app needs no change.
create or replace function issue_invoice(
  p_doc_type   text,
  p_doc_date   date,
  p_from       date,
  p_to         date,
  p_customer_id uuid,
  p_cust_name  text,
  p_cust_addr  text,
  p_cust_tax_id text,
  p_base       numeric,   -- ignored: recomputed from p_sale_ids
  p_vat        numeric,   -- ignored
  p_grand      numeric,   -- ignored
  p_items      jsonb,
  p_employee_id text,
  p_sale_ids   uuid[]
) returns invoices
language plpgsql security definer set search_path = public as $$
declare
  v_prefix text := doc_prefix(p_doc_type);
  v_period text := doc_period(p_doc_date);
  v_amt    record;
  v_no     int;
  v_row    invoices;
begin
  if v_prefix = 'XX' then
    raise exception 'ไม่รู้จักชนิดเอกสาร %', p_doc_type;
  end if;
  if p_doc_type = 'receipt' then
    raise exception 'ใบเสร็จรับเงินต้องออกผ่าน issue_receipt (ตัดยอดพร้อมกัน)';
  end if;

  -- Checks run BEFORE the counter is touched, so a refused request never
  -- burns a running number.
  select * into v_amt from doc_check_and_amounts(p_doc_type, p_customer_id, p_sale_ids);

  insert into invoice_counters (prefix, period, last_no)
  values (v_prefix, v_period, 1)
  on conflict (prefix, period)
    do update set last_no = invoice_counters.last_no + 1
  returning last_no into v_no;

  insert into invoices (
    doc_no, doc_type, doc_date, period_from, period_to, customer_id,
    cust_name, cust_addr, cust_tax_id, base, vat, grand, items, employee_id, sale_ids
  ) values (
    v_prefix || v_period || '-' || lpad(v_no::text, 4, '0'),
    p_doc_type, p_doc_date, p_from, p_to, p_customer_id,
    p_cust_name, p_cust_addr, p_cust_tax_id, v_amt.o_base, v_amt.o_vat, v_amt.o_grand,
    coalesce(p_items, '[]'::jsonb), p_employee_id, p_sale_ids
  ) returning * into v_row;

  return v_row;
end $$;

grant execute on function issue_invoice(text,date,date,date,uuid,text,text,text,numeric,numeric,numeric,jsonb,text,uuid[]) to anon, authenticated;

-- Same signature as migration-receipt-settle.sql, so the app needs no change.
create or replace function issue_receipt(
  p_doc_date    date,
  p_from        date,
  p_to          date,
  p_customer_id uuid,
  p_cust_name   text,
  p_cust_addr   text,
  p_cust_tax_id text,
  p_base        numeric,   -- ignored: recomputed from p_sale_ids
  p_vat         numeric,   -- ignored
  p_grand       numeric,   -- ignored
  p_items       jsonb,
  p_employee_id text,
  p_sale_ids    uuid[],
  p_method      text
) returns invoices
language plpgsql security definer set search_path = public as $$
declare
  v_prefix text := doc_prefix('receipt');   -- REC
  v_period text := doc_period(p_doc_date);
  v_amt    record;
  v_no     int;
  v_row    invoices;
begin
  select * into v_amt from doc_check_and_amounts('receipt', p_customer_id, p_sale_ids);

  insert into invoice_counters (prefix, period, last_no)
  values (v_prefix, v_period, 1)
  on conflict (prefix, period)
    do update set last_no = invoice_counters.last_no + 1
  returning last_no into v_no;

  insert into invoices (
    doc_no, doc_type, doc_date, period_from, period_to, customer_id,
    cust_name, cust_addr, cust_tax_id, base, vat, grand, items, employee_id, sale_ids
  ) values (
    v_prefix || v_period || '-' || lpad(v_no::text, 4, '0'),
    'receipt', p_doc_date, p_from, p_to, p_customer_id,
    p_cust_name, p_cust_addr, p_cust_tax_id, v_amt.o_base, v_amt.o_vat, v_amt.o_grand,
    coalesce(p_items, '[]'::jsonb), p_employee_id, p_sale_ids
  ) returning * into v_row;

  -- Settle the covered sales in the SAME transaction (unchanged).
  update sales
     set paid = true,
         paid_date = p_doc_date,
         method = coalesce(nullif(p_method, ''), method)
   where id = any(p_sale_ids) and paid = false;

  return v_row;
end $$;

grant execute on function issue_receipt(date,date,date,uuid,text,text,text,numeric,numeric,numeric,jsonb,text,uuid[],text) to anon, authenticated;
