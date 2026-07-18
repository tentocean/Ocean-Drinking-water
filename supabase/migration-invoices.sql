-- ============================================================
-- MIGRATION: running tax-invoice numbers + issued-document ledger
-- Run this in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to run more than once.
--
-- Why a ledger at all: before this, the document number was computed on the
-- fly from the date + customer id, so it changed whenever the date range
-- changed and nothing recorded that a document had ever been issued. The
-- Revenue Department requires numbers to be sequential, non-duplicating and
-- traceable, so issued documents now live in a real table.
-- ============================================================

-- Issued documents. Rows are NEVER deleted (a cancelled tax invoice must stay
-- on the books with its number burnt) — see cancel_invoice() below.
create table if not exists invoices (
  id uuid primary key default gen_random_uuid(),
  doc_no text not null unique,
  doc_type text not null,
  doc_date date not null,
  period_from date not null,
  period_to date not null,
  customer_id uuid references customers(id),
  -- name/address/tax id are SNAPSHOTS: a reprint years later must show what
  -- was actually issued, even if the customer record has since been edited.
  cust_name text not null,
  cust_addr text,
  cust_tax_id text,
  base numeric not null,
  vat numeric not null,
  grand numeric not null,
  items jsonb not null default '[]'::jsonb,
  status text not null default 'issued' check (status in ('issued','cancelled')),
  cancel_reason text,
  employee_id text references employees(id),
  created_at timestamptz not null default now()
);

create index if not exists invoices_doc_date_idx on invoices(doc_date);
create index if not exists invoices_customer_idx on invoices(customer_id);
create index if not exists invoices_doc_type_idx on invoices(doc_type);

-- One running counter per (prefix, Thai YYMM). Numbers reset each month.
create table if not exists invoice_counters (
  prefix text not null,
  period text not null,          -- Thai year + month, e.g. '6807'
  last_no int not null default 0,
  primary key (prefix, period)
);

-- taxreceipt -> IV, delivery -> DN, cash -> RC, billing -> BL, invdelivery -> IN
create or replace function doc_prefix(p_doc_type text) returns text
language sql immutable as $$
  select case p_doc_type
    when 'taxreceipt'  then 'IV'
    when 'delivery'    then 'DN'
    when 'cash'        then 'RC'
    when 'billing'     then 'BL'
    when 'invdelivery' then 'IN'
    else 'XX' end;
$$;

-- Thai buddhist year (2 digits) + month, e.g. 2025-07-18 -> '6807'
create or replace function doc_period(p_date date) returns text
language sql immutable as $$
  select lpad((((extract(year from p_date)::int + 543) % 100))::text, 2, '0')
      || to_char(p_date, 'MM');
$$;

-- Allocates the next number AND writes the document in one transaction, so a
-- failed insert can never burn a number and two concurrent calls can never
-- collide (the ON CONFLICT ... RETURNING takes a row lock on the counter).
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
  p_employee_id text
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
    cust_name, cust_addr, cust_tax_id, base, vat, grand, items, employee_id
  ) values (
    v_prefix || v_period || '-' || lpad(v_no::text, 4, '0'),
    p_doc_type, p_doc_date, p_from, p_to, p_customer_id,
    p_cust_name, p_cust_addr, p_cust_tax_id, p_base, p_vat, p_grand,
    coalesce(p_items, '[]'::jsonb), p_employee_id
  ) returning * into v_row;

  return v_row;
end $$;

-- Cancelling keeps the row and the number (that's the point of a ledger) and
-- only flips status, so the number can never be handed out again.
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
  return v_row;
end $$;

-- ============================================================
-- ROW LEVEL SECURITY
--
-- Deliberately tighter than customers/sales/expenses: the ledger is readable
-- by anyone holding the anon key (the app needs to list and reprint), but
-- there is NO insert/update/delete policy at all. Every write goes through
-- the security-definer functions above, which is what guarantees numbers stay
-- sequential and that nothing can be quietly deleted from the books.
-- ============================================================

alter table invoices enable row level security;
alter table invoice_counters enable row level security;

drop policy if exists invoices_select on invoices;
create policy invoices_select on invoices for select using (true);

-- counters: no policy at all -> only the definer functions can touch them.

grant execute on function issue_invoice(text,date,date,date,uuid,text,text,text,numeric,numeric,numeric,jsonb,text) to anon, authenticated;
grant execute on function cancel_invoice(uuid,text) to anon, authenticated;
