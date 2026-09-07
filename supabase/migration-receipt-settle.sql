-- ============================================================
-- MIGRATION 3: issue a ใบเสร็จรับเงิน that ALSO settles the sales it covers
-- Run this in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to run more than once. Run AFTER migration-invoices.sql,
-- migration-invoice-payments.sql and migration-receipt-doctype.sql.
--
-- Why: for credit customers (e.g. Novotel, โรงแรมสตาร์) we issue a
-- ใบส่งสินค้า/ใบกำกับภาษี (DN) + ใบวางบิล/ใบแจ้งหนี้ (BL) together, both frozen
-- onto the SAME sales rows. When the customer pays we issue a ใบเสร็จรับเงิน
-- (REC). Payment status is derived from the sales rows (see
-- migration-invoice-payments.sql), so marking those sales paid HERE cuts the
-- outstanding balance on the paired DN and BL automatically — no per-document
-- payment flag to keep in sync.
--
-- issue_receipt() does both in ONE transaction, so a REC can never exist
-- without its settlement, and a failed settlement can never burn a number.
-- ============================================================

create or replace function issue_receipt(
  p_doc_date    date,
  p_from        date,
  p_to          date,
  p_customer_id uuid,
  p_cust_name   text,
  p_cust_addr   text,
  p_cust_tax_id text,
  p_base        numeric,
  p_vat         numeric,
  p_grand       numeric,
  p_items       jsonb,
  p_employee_id text,
  p_sale_ids    uuid[],
  p_method      text
) returns invoices
language plpgsql security definer set search_path = public as $$
declare
  v_prefix text := doc_prefix('receipt');   -- REC
  v_period text := doc_period(p_doc_date);
  v_no int;
  v_row invoices;
begin
  -- Same counter-locking dance as issue_invoice: allocate the next running
  -- number under a row lock so two concurrent receipts can't collide.
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
    p_cust_name, p_cust_addr, p_cust_tax_id, p_base, p_vat, p_grand,
    coalesce(p_items, '[]'::jsonb), p_employee_id, coalesce(p_sale_ids, '{}')
  ) returning * into v_row;

  -- Settle the covered sales in the SAME transaction. Only rows still unpaid
  -- are touched, so re-running or a partly-settled range is safe.
  if array_length(coalesce(p_sale_ids, '{}'), 1) is not null then
    update sales
       set paid = true,
           paid_date = p_doc_date,
           method = coalesce(nullif(p_method, ''), method)
     where id = any(p_sale_ids) and paid = false;
  end if;

  return v_row;
end $$;

grant execute on function issue_receipt(date,date,date,uuid,text,text,text,numeric,numeric,numeric,jsonb,text,uuid[],text) to anon, authenticated;

-- Cancelling a receipt must reverse its settlement: the receipt is what marked
-- the sales paid, so voiding it puts the balance back on the paired DN/BL
-- (again, derived from the same sales). Other document types don't touch sales.
create or replace function cancel_invoice(p_id uuid, p_reason text)
returns invoices
language plpgsql security definer set search_path = public as $$
declare v_row invoices;
begin
  update invoices
     set status = 'cancelled', cancel_reason = coalesce(p_reason, '')
   where id = p_id and status = 'issued'
  returning * into v_row;
  if v_row.id is null then
    raise exception 'ไม่พบเอกสาร หรือถูกยกเลิกไปแล้ว';
  end if;

  if v_row.doc_type = 'receipt'
     and array_length(v_row.sale_ids, 1) is not null then
    update sales
       set paid = false, paid_date = null
     where id = any(v_row.sale_ids);
  end if;

  return v_row;
end $$;
