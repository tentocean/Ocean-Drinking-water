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

create or replace function my_employee_id() returns text
language sql stable security definer set search_path = public as $$
  select employee_id from profiles where id = auth.uid();
$$;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table employees enable row level security;
alter table profiles enable row level security;
alter table customers enable row level security;
alter table sales enable row level security;
alter table expenses enable row level security;
alter table factory_expenses enable row level security;

-- employees: any signed-in user can read (needed for dropdowns); only owner writes
create policy employees_select on employees for select
  using (auth.role() = 'authenticated');
create policy employees_write on employees for all
  using (is_owner()) with check (is_owner());

-- profiles: read own row, or all rows if owner. No client-side writes.
create policy profiles_select on profiles for select
  using (id = auth.uid() or is_owner());

-- customers: owner sees/writes all; employee sees/writes only their own route
create policy customers_select on customers for select
  using (is_owner() or employee_id = my_employee_id());
create policy customers_insert on customers for insert
  with check (is_owner() or employee_id = my_employee_id());
create policy customers_update on customers for update
  using (is_owner() or employee_id = my_employee_id())
  with check (is_owner() or employee_id = my_employee_id());

-- sales: owner sees/writes all; employee sees/writes only their own route
create policy sales_select on sales for select
  using (is_owner() or employee_id = my_employee_id());
create policy sales_insert on sales for insert
  with check (is_owner() or employee_id = my_employee_id());
create policy sales_update on sales for update
  using (is_owner() or employee_id = my_employee_id())
  with check (is_owner() or employee_id = my_employee_id());
create policy sales_delete on sales for delete
  using (is_owner() or employee_id = my_employee_id());

-- expenses: owner sees/writes/deletes all; employee sees/writes/deletes only their own route
create policy expenses_select on expenses for select
  using (is_owner() or employee_id = my_employee_id());
create policy expenses_insert on expenses for insert
  with check (is_owner() or employee_id = my_employee_id());
create policy expenses_delete on expenses for delete
  using (is_owner() or employee_id = my_employee_id());

-- factory_expenses: owner only
create policy factory_expenses_all on factory_expenses for all
  using (is_owner()) with check (is_owner());

-- ============================================================
-- STORAGE — payment slip uploads
-- ============================================================

insert into storage.buckets (id, name, public)
values ('slips', 'slips', false)
on conflict (id) do nothing;

-- objects are stored as: slips/{employee_id}/{filename}
create policy slips_owner_all on storage.objects for all
  using (bucket_id = 'slips' and is_owner())
  with check (bucket_id = 'slips' and is_owner());

create policy slips_employee_rw on storage.objects for all
  using (bucket_id = 'slips' and (storage.foldername(name))[1] = my_employee_id())
  with check (bucket_id = 'slips' and (storage.foldername(name))[1] = my_employee_id());

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
-- Create auth users in Dashboard -> Authentication -> Users, then run
-- the profile-linking snippet from DEPLOY.md for each one.
-- ============================================================
