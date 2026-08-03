-- Add the standalone "ใบเสร็จรับเงิน" (receipt) document type.
--
-- The invoices table has no CHECK on doc_type, so the new value needs no table
-- change — but doc_prefix() (not the frontend DOCT table) is what stamps the
-- running number, so it MUST learn the new type or every receipt would be
-- numbered 'XX....'. Run this once in the Supabase SQL Editor BEFORE issuing
-- the first ใบเสร็จรับเงิน. Safe to re-run (create or replace, touches no data).
--
-- prefix REC -> e.g. REC6809-0001. The frontend keeps the matching entry in
-- DOCT (ระบบจัดการลูกค้าน้ำดื่ม.dc.html).

create or replace function doc_prefix(p_doc_type text) returns text
language sql immutable as $$
  select case p_doc_type
    when 'taxreceipt'  then 'IV'
    when 'delivery'    then 'DN'
    when 'cash'        then 'RC'
    when 'receipt'     then 'REC'
    when 'billing'     then 'BL'
    when 'invdelivery' then 'IN'
    else 'XX' end;
$$;
