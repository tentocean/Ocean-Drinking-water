-- ============================================================
-- MIGRATION 5: ใบเสร็จรับเงินย้อนหลังสำหรับบิลที่รับเงินไปแล้ว
-- Run this in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to run more than once. Run AFTER migration-invoice-guards.sql.
-- Run it BEFORE using the "🧾 ออกใบเสร็จให้บิลที่จ่ายแล้ว" button.
--
-- Why: the app can now issue a REC for bills that were already marked paid
-- (รับชำระ without a receipt). issue_receipt already leaves such bills alone
-- (it only settles rows still unpaid), but cancel_invoice used to put EVERY
-- sale of a cancelled receipt back to unpaid — so cancelling a receipt issued
-- for already-paid bills would wrongly re-open debts that were paid in cash.
--
-- Fix: each receipt records which sales it actually settled
-- (settled_sale_ids), and cancelling reverses only those. Receipts issued
-- before this migration have NULL there and keep the old behaviour (reverse
-- all of sale_ids) — they were all issued for unpaid bills, except the known
-- double click REC6909-0016, whose ฿138 bill was settled by REC6909-0015.
-- ============================================================

alter table invoices add column if not exists settled_sale_ids uuid[];

-- Same signature as before, so the app needs no change.
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
  v_prefix  text := doc_prefix('receipt');   -- REC
  v_period  text := doc_period(p_doc_date);
  v_amt     record;
  v_settled uuid[];
  v_no      int;
  v_row     invoices;
begin
  -- Locks the sales, checks them, recomputes the amounts (migration 4).
  select * into v_amt from doc_check_and_amounts('receipt', p_customer_id, p_sale_ids);

  -- The rows still unpaid are the ones this receipt settles; the rest were
  -- paid earlier and the receipt only documents that payment.
  select coalesce(array_agg(id), '{}') into v_settled
    from sales where id = any(p_sale_ids) and paid = false;

  insert into invoice_counters (prefix, period, last_no)
  values (v_prefix, v_period, 1)
  on conflict (prefix, period)
    do update set last_no = invoice_counters.last_no + 1
  returning last_no into v_no;

  insert into invoices (
    doc_no, doc_type, doc_date, period_from, period_to, customer_id,
    cust_name, cust_addr, cust_tax_id, base, vat, grand, items, employee_id,
    sale_ids, settled_sale_ids
  ) values (
    v_prefix || v_period || '-' || lpad(v_no::text, 4, '0'),
    'receipt', p_doc_date, p_from, p_to, p_customer_id,
    p_cust_name, p_cust_addr, p_cust_tax_id, v_amt.o_base, v_amt.o_vat, v_amt.o_grand,
    coalesce(p_items, '[]'::jsonb), p_employee_id, p_sale_ids, v_settled
  ) returning * into v_row;

  update sales
     set paid = true,
         paid_date = p_doc_date,
         method = coalesce(nullif(p_method, ''), method)
   where id = any(v_settled);

  return v_row;
end $$;

grant execute on function issue_receipt(date,date,date,uuid,text,text,text,numeric,numeric,numeric,jsonb,text,uuid[],text) to anon, authenticated;

-- Cancelling a receipt reverses only the settlement it made.
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

  if v_row.doc_type = 'receipt' then
    update sales
       set paid = false, paid_date = null
     where id = any(coalesce(v_row.settled_sale_ids, v_row.sale_ids));
  end if;

  return v_row;
end $$;

grant execute on function cancel_invoice(uuid, text) to anon, authenticated;
