-- ============================================================
-- MIGRATION 2: lock the sales an invoice covers
-- Run this in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to run more than once. Run AFTER migration-invoices.sql.
--
-- Payment status is deliberately NOT stored on the invoice. It is derived
-- from the `paid` flag on the sales rows the invoice covers, so there is one
-- source of truth and "รับชำระ" in the customers tab and the document
-- register can never disagree.
--
-- What this migration adds is the *link*: which sales rows a given invoice
-- covers, frozen at the moment it was issued. Without it the app would have
-- to re-match by (customer + date range), and a sale entered later inside
-- that range would silently join an already-printed invoice and change its
-- outstanding balance.
-- ============================================================

alter table invoices add column if not exists sale_ids uuid[] not null default '{}';

-- The old signature has to go explicitly — adding a parameter would otherwise
-- create a second overload and PostgREST could not tell them apart.
drop function if exists issue_invoice(text,date,date,date,uuid,text,text,text,numeric,numeric,numeric,jsonb,text);

create or replace function issue_invoice(
  p_doc_type   text,
  p_doc_date   date,
  p_from       date,
  p_to         date,
  p_customer_id uuid,
  p_cust_name  text,
  p_cust_addr  text,
  p_cust_tax_id text,
  p_base       numeric,
  p_vat        numeric,
  p_grand      numeric,
  p_items      jsonb,
  p_employee_id text,
  p_sale_ids   uuid[]
) returns invoices
language plpgsql security definer set search_path = public as $$
declare
  v_prefix text := doc_prefix(p_doc_type);
  v_period text := doc_period(p_doc_date);
  v_no int;
  v_row invoices;
begin
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
    p_cust_name, p_cust_addr, p_cust_tax_id, p_base, p_vat, p_grand,
    coalesce(p_items, '[]'::jsonb), p_employee_id, coalesce(p_sale_ids, '{}')
  ) returning * into v_row;

  return v_row;
end $$;

grant execute on function issue_invoice(text,date,date,date,uuid,text,text,text,numeric,numeric,numeric,jsonb,text,uuid[]) to anon, authenticated;
