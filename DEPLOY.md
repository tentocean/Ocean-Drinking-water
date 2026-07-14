# วิธี Deploy ระบบ OCEAN Drinking Water

ระบบนี้เป็นเว็บแบบ static (ไม่มี build step) ที่เชื่อมต่อกับ Supabase (ฐานข้อมูล + auth) ตรงจากฝั่งเบราว์เซอร์
ขั้นตอนด้านล่างต้องทำเองเพราะเป็นการเข้าบัญชี Supabase / GitHub / Cloudflare ของคุณ — เครื่องที่ใช้รันงานนี้ไม่มี credential ของบัญชีเหล่านี้อยู่เลย

---

## ขั้นตอนที่ 1 — สร้างตาราง + สิทธิ์การเข้าถึงใน Supabase

1. เข้า [supabase.com/dashboard](https://supabase.com/dashboard) → เลือกโปรเจกต์ (หรือสร้างใหม่ถ้ายังไม่มี)
2. ไปที่เมนู **SQL Editor** → **New query**
3. เปิดไฟล์ [`supabase/schema.sql`](supabase/schema.sql) ในโปรเจกต์นี้ คัดลอกทั้งหมด แล้ววางในช่อง SQL Editor
4. กด **Run**

ขั้นตอนนี้จะสร้าง: ตาราง `employees`, `customers`, `sales`, `expenses`, `factory_expenses`, `profiles`, กฎ Row Level Security (RLS) ที่ทำให้พนักงานเห็นเฉพาะข้อมูลสายตัวเอง ส่วนเจ้าของเห็นทั้งหมด, storage bucket ชื่อ `slips` สำหรับเก็บรูปสลิปโอนเงิน, และ seed ข้อมูลพนักงาน 5 คน + ลูกค้า 16 รายที่มีอยู่แล้วในระบบเดิม

**หมายเหตุ:** ข้อมูลการขาย/ค่าใช้จ่ายเดิมในเว็บ (ที่เห็นตอนเดโม) เป็นข้อมูลสุ่มขึ้นมาเพื่อสาธิตเท่านั้น จะ**ไม่ถูก**ย้ายเข้าฐานข้อมูลจริง — ตารางยอดขาย/ค่าใช้จ่ายจะเริ่มต้นว่างเปล่า พร้อมให้กรอกข้อมูลจริงตั้งแต่วันนี้เป็นต้นไป

---

## ขั้นตอนที่ 2 — สร้างบัญชีผู้ใช้ (เจ้าของ + พนักงาน 5 คน)

ระบบใหม่ใช้อีเมล+รหัสผ่านจริงแทนรหัสผ่านทดลองเดิม แต่ละคนต้องมีบัญชีของตัวเอง

1. ไปที่เมนู **Authentication → Users** → **Add user** (เลือก "Create new user", ระบุอีเมล+รหัสผ่าน, ติ๊ก "Auto Confirm User")
2. ทำซ้ำ 6 ครั้ง สำหรับ: เจ้าของกิจการ, แจ็ค (e1), บอย (e2), แปดริ้ว (e3), OEM/ETC (e4), อื่นๆ (e5)
3. หลังสร้างครบแล้ว กลับไปที่ **SQL Editor** แล้วรัน (แก้อีเมลให้ตรงกับที่สร้างจริง):

```sql
-- เจ้าของกิจการ
insert into profiles (id, role, employee_id, display_name)
select id, 'owner', null, 'เจ้าของกิจการ' from auth.users where email = 'owner@yourdomain.com';

-- พนักงาน (แก้อีเมลและ employee_id ให้ตรงกับแต่ละคน)
insert into profiles (id, role, employee_id, display_name)
select id, 'employee', 'e1', 'แจ็ค' from auth.users where email = 'jack@yourdomain.com';

insert into profiles (id, role, employee_id, display_name)
select id, 'employee', 'e2', 'บอย' from auth.users where email = 'boy@yourdomain.com';

insert into profiles (id, role, employee_id, display_name)
select id, 'employee', 'e3', 'แปดริ้ว' from auth.users where email = 'paedriw@yourdomain.com';

insert into profiles (id, role, employee_id, display_name)
select id, 'employee', 'e4', 'OEM / ETC' from auth.users where email = 'oem@yourdomain.com';

insert into profiles (id, role, employee_id, display_name)
select id, 'employee', 'e5', 'อื่นๆ' from auth.users where email = 'other@yourdomain.com';
```

ใช้อีเมลจริงของแต่ละคน (ไม่จำเป็นต้องเป็นอีเมลใช้งานจริง แค่เป็น username สำหรับ login ก็ได้ เช่น `jack@ocean.internal`)

---

## ขั้นตอนที่ 3 — ส่ง Project URL + anon key กลับมา

ไปที่ **Settings → API** ในโปรเจกต์ Supabase คัดลอก 2 ค่านี้ส่งกลับมาให้ผมใส่ในเว็บ (ทั้งสองค่านี้ปลอดภัยที่จะฝังในโค้ดฝั่ง client — ความปลอดภัยจริงมาจาก RLS ไม่ใช่การซ่อนค่านี้):

- **Project URL** (เช่น `https://xxxxxxxx.supabase.co`)
- **anon public key** (คีย์ยาวๆ ที่ระบุว่า `anon` `public`)

⚠️ อย่าส่ง **service_role key** มาให้ — คีย์นั้นเป็นความลับ ไม่ควรอยู่ในโค้ดฝั่ง client

หลังจากได้ค่านี้แล้ว ผมจะใส่ในไฟล์ `ระบบจัดการลูกค้าน้ำดื่ม.dc.html` (บรรทัดที่มี `SUPABASE_URL` / `SUPABASE_ANON_KEY`) แล้วทดสอบระบบจริงให้ก่อนที่คุณจะ deploy ขึ้นเว็บสาธารณะ

---

## ขั้นตอนที่ 4 — Push ขึ้น GitHub

1. สร้าง repo เปล่าใหม่ที่ [github.com/new](https://github.com/new) (ตั้งชื่อตามใจ เช่น `ocean-drinking-water`) — **ไม่ต้อง** ติ๊ก "Add README"
2. ส่ง URL ของ repo กลับมา (เช่น `https://github.com/yourname/ocean-drinking-water.git`)
3. รันคำสั่งนี้เอง (เครื่องนี้ยังไม่มี GitHub credential):

```bash
cd "ocean drinking water"
git remote add origin <URL ที่ได้จากขั้นตอนที่ 2>
git push -u origin main
```

---

## ขั้นตอนที่ 5 — เชื่อม Cloudflare Pages

1. เข้า [dash.cloudflare.com](https://dash.cloudflare.com) → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**
2. เลือก repo ที่เพิ่ง push ไป
3. ตั้งค่า build:
   - **Framework preset:** None
   - **Build command:** (เว้นว่าง)
   - **Build output directory:** `/`
4. กด **Save and Deploy**

เว็บจะขึ้นที่ URL แบบ `xxxxx.pages.dev` — ใส่ custom domain เพิ่มได้ในภายหลังจากเมนู Custom domains ของโปรเจกต์นั้น

---

## สรุปลำดับ

| ขั้นตอน | ใครทำ |
|---|---|
| 1. รัน schema.sql | คุณ (Supabase SQL Editor) |
| 2. สร้างบัญชีผู้ใช้ 6 คน + link profiles | คุณ (Supabase Dashboard + SQL Editor) |
| 3. ส่ง Project URL + anon key | คุณ → ผม |
| ผมใส่ config + ทดสอบระบบจริง | ผม |
| 4. Push ขึ้น GitHub | คุณ |
| 5. เชื่อม Cloudflare Pages | คุณ |
