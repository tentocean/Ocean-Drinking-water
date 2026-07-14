-- OCEAN Drinking Water — schema + RLS + seed data
-- Run this once in: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to re-run partially, but intended as a single first-time setup script.

create extension if not exists pgcrypto;

-- ============================================================
-- TABLES
-- ============================================================

create table if not exists employees (
  id text primary key,
  name text not null,
  route text,
  dot text,
  sort_order int not null default 0
);

-- Only ever holds one row: the owner's account. Employees don't log in —
-- see the RLS section below for what that means for data access.
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','employee')),
  employee_id text references employees(id),
  display_name text
);

create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  tax_id text,
  contact text,
  employee_id text references employees(id),
  created_at timestamptz not null default now()
);

create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  group_id text not null,
  sale_date date not null,
  employee_id text not null references employees(id),
  customer_id uuid references customers(id),
  type text not null,
  qty numeric not null,
  price numeric not null,
  total numeric not null,
  method text not null check (method in ('cash','transfer','credit')),
  paid boolean not null default true,
  paid_date date,
  slip_url text,
  created_at timestamptz not null default now()
);

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  expense_date date not null,
  employee_id text not null references employees(id),
  category text not null,
  amount numeric not null,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists factory_expenses (
  id uuid primary key default gen_random_uuid(),
  entry_date date not null,
  category text not null,
  variant text,
  qty numeric,
  unit_price numeric,
  total numeric not null,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists sales_date_idx on sales(sale_date);
create index if not exists sales_employee_idx on sales(employee_id);
create index if not exists expenses_date_idx on expenses(expense_date);
create index if not exists expenses_employee_idx on expenses(employee_id);
create index if not exists factory_expenses_date_idx on factory_expenses(entry_date);
create index if not exists customers_employee_idx on customers(employee_id);

-- ============================================================
-- RLS HELPER FUNCTIONS
-- ============================================================

create or replace function is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'owner');
$$;

-- ============================================================
-- ROW LEVEL SECURITY
--
-- Only the owner logs in (real Supabase Auth). Employees use the app with
-- no credential at all — they just tap their name in the picker. That
-- means Postgres has no way to tell "employee A" apart from "employee B"
-- (or from any other visitor) at the database layer: anyone who has the
-- deployed URL can read and write customers/sales/expenses for ANY route,
-- not just their own, since there's no login to scope by. The picker only
-- controls what the *app UI* tags a new record with — it is not a security
-- boundary. This is intentional (chosen for lower login friction for
-- delivery staff) but worth remembering if the URL is ever shared beyond
-- the 5 staff it's meant for. factory_expenses and profiles stay
-- owner-only since only the owner ever authenticates.
-- ============================================================

alter table employees enable row level security;
alter table profiles enable row level security;
alter table customers enable row level security;
alter table sales enable row level security;
alter table expenses enable row level security;
alter table factory_expenses enable row level security;

-- employees: anyone can read (needed for the picker/dropdowns); only owner writes
create policy employees_select on employees for select
  using (true);
create policy employees_write on employees for all
  using (is_owner()) with check (is_owner());

-- profiles: read own row (owner only ever has one). No client-side writes.
create policy profiles_select on profiles for select
  using (id = auth.uid());

-- customers / sales / expenses: open to anyone holding the anon key (owner
-- included) — see the RLS note above for why there's no per-employee scoping.
create policy customers_all on customers for all
  using (true) with check (true);
create policy sales_all on sales for all
  using (true) with check (true);
create policy expenses_all on expenses for all
  using (true) with check (true);

-- factory_expenses: owner only (matches the UI, which only shows this tab to the owner)
create policy factory_expenses_all on factory_expenses for all
  using (is_owner()) with check (is_owner());

-- ============================================================
-- STORAGE — payment slip uploads
-- ============================================================

insert into storage.buckets (id, name, public)
values ('slips', 'slips', false)
on conflict (id) do nothing;

-- Open like customers/sales/expenses above — no per-employee credential to scope by.
create policy slips_all on storage.objects for all
  using (bucket_id = 'slips')
  with check (bucket_id = 'slips');

-- ============================================================
-- SEED DATA — real employees & customers (matches current app)
-- ============================================================

insert into employees (id, name, route, dot, sort_order) values
  ('e1', 'แจ็ค',       'สายแจ็ค',       '#1c5f96', 1),
  ('e2', 'บอย',        'สายบอย',        '#157a52', 2),
  ('e3', 'แปดริ้ว',     'สายแปดริ้ว',    '#b45309', 3),
  ('e4', 'OEM / ETC',  'สาย OEM / ETC', '#7a52b4', 4),
  ('e5', 'อื่นๆ',       'สายอื่นๆ',      '#64748b', 5)
on conflict (id) do nothing;

insert into customers (id, name, phone, address, employee_id) values
  (gen_random_uuid(), 'ร้านอาหารครัวคุณแม่', '081-234-5678', 'ถ.สุขุมวิท ซ.12', 'e1'),
  (gen_random_uuid(), 'มินิมาร์ท 24 ชม.', '082-345-6789', 'ปากซอยรัชดา 7', 'e1'),
  (gen_random_uuid(), 'โรงเรียนอนุบาลดาวเด่น', '083-456-7890', 'ถ.พหลโยธิน', 'e1'),
  (gen_random_uuid(), 'คลินิกหมอสมศรี', '084-567-8901', 'ตลาดนัดเมืองใหม่', 'e1'),
  (gen_random_uuid(), 'ร้านก๋วยเตี๋ยวเรือป้านิด', '085-678-9012', 'ตลาดสดเทศบาล', 'e2'),
  (gen_random_uuid(), 'แผงผลไม้เจ๊หมวย', '086-789-0123', 'ตลาดสดเทศบาล แผง 14', 'e2'),
  (gen_random_uuid(), 'ร้านกาแฟ Bean & Brew', '087-890-1234', 'หน้าตลาดสด', 'e2'),
  (gen_random_uuid(), 'หอพักนักศึกษารุ่งเรือง', '088-901-2345', 'ซ.มหาวิทยาลัย 3', 'e2'),
  (gen_random_uuid(), 'บริษัท ไทยพลาสติก จก.', '089-012-3456', 'นิคมฯ โซน B', 'e3'),
  (gen_random_uuid(), 'โรงงานเย็บผ้า เอส.ที.', '090-123-4567', 'นิคมฯ โซน C', 'e3'),
  (gen_random_uuid(), 'แคนทีนโรงงานไทยเมทัล', '091-234-5678', 'นิคมฯ โซน A', 'e3'),
  (gen_random_uuid(), 'รีสอร์ทริมธาร', '092-345-6789', 'ถ.เลียบคลอง ชานเมือง', 'e4'),
  (gen_random_uuid(), 'ร้านชำป้าสมพร', '093-456-7890', 'หมู่บ้านสุขสันต์', 'e4'),
  (gen_random_uuid(), 'ฟิตเนสสตูดิโอ FIT+', '094-567-8901', 'ห้างชานเมืองพลาซ่า', 'e4'),
  (gen_random_uuid(), 'ลูกค้าหน้าร้าน (เงินสด)', '-', 'หน้าโรงงาน', 'e5'),
  (gen_random_uuid(), 'ลูกค้าทั่วไป / ขายส่ง', '-', '-', 'e5');

-- ============================================================
-- NEXT STEP (do this after running the above):
-- Create ONE auth user in Dashboard -> Authentication -> Users (the owner),
-- then run the profile-linking snippet from DEPLOY.md.
-- ============================================================
