# วิธี Deploy ระบบ OCEAN Drinking Water

ระบบนี้เป็นเว็บแบบ static (ไม่มี build step) ที่เชื่อมต่อกับ Supabase (ฐานข้อมูล + auth) ตรงจากฝั่งเบราว์เซอร์
ขั้นตอนด้านล่างต้องทำเองเพราะเป็นการเข้าบัญชี Supabase / GitHub / Cloudflare ของคุณ — เครื่องที่ใช้รันงานนี้ไม่มี credential ของบัญชีเหล่านี้อยู่เลย

---

## ขั้นตอนที่ 1 — สร้างตาราง + สิทธิ์การเข้าถึงใน Supabase

1. เข้า [supabase.com/dashboard](https://supabase.com/dashboard) → เลือกโปรเจกต์ (หรือสร้างใหม่ถ้ายังไม่มี)
2. ไปที่เมนู **SQL Editor** → **New query**
3. เปิดไฟล์ [`supabase/schema.sql`](supabase/schema.sql) ในโปรเจกต์นี้ คัดลอกทั้งหมด แล้ววางในช่อง SQL Editor
4. กด **Run**
5. **New query** อีกครั้ง → วาง [`supabase/migration-invoices.sql`](supabase/migration-invoices.sql) ทั้งหมด → **Run**
   (ระบบเลขรันใบกำกับภาษี — แยกไฟล์เพราะกฎสิทธิ์เข้มกว่าตารางอื่น: อ่านได้ทุกคน แต่**เขียนได้ผ่าน function เท่านั้น** เพื่อกันเลขซ้ำ/เลขหาย)

ขั้นตอนนี้จะสร้าง: ตาราง `employees`, `customers`, `sales`, `expenses`, `factory_expenses`, `profiles`, storage bucket ชื่อ `slips` สำหรับเก็บรูปสลิปโอนเงิน, และ seed ข้อมูลพนักงาน 5 คน + ลูกค้า 16 รายที่มีอยู่แล้วในระบบเดิม

**เรื่องสิทธิ์การเข้าถึง (RLS):** มีแค่ "เจ้าของ" เท่านั้นที่ login ด้วยอีเมล+รหัสผ่านจริง ฝั่งพนักงานไม่ต้อง login เลย — แค่แตะเลือกชื่อตัวเองแล้วใช้งานได้ทันที เพื่อให้ตรงกับที่ต้องการนี้ ตาราง `customers` / `sales` / `expenses` (และ storage bucket `slips`) จึง**เปิดให้อ่าน/เขียนได้จากทุกคนที่เข้าเว็บถึง** โดยไม่ต้องมี credential — ตัวเว็บเองเป็นคนกำหนดว่าข้อมูลที่กรอกจะถูกติดชื่อพนักงานคนไหน ไม่ใช่ระบบฐานข้อมูล พูดง่ายๆ คือ**ใครก็ตามที่มีลิงก์เว็บนี้ สามารถดู/แก้ไขข้อมูลลูกค้าและยอดขายของทุกสายได้ ไม่ใช่แค่สายตัวเอง** — เหมาะกับกรณีที่ลิงก์นี้ให้เฉพาะพนักงาน 5 คนในทีมเท่านั้น ไม่ควรแชร์ต่อสาธารณะ ส่วน `factory_expenses` (ค่าใช้จ่ายโรงงาน) ยังคงจำกัดเฉพาะเจ้าของเท่านั้น เพราะต้อง login จริง

**หมายเหตุ:** ข้อมูลการขาย/ค่าใช้จ่ายเดิมในเว็บ (ที่เห็นตอนเดโม) เป็นข้อมูลสุ่มขึ้นมาเพื่อสาธิตเท่านั้น จะ**ไม่ถูก**ย้ายเข้าฐานข้อมูลจริง — ตารางยอดขาย/ค่าใช้จ่ายจะเริ่มต้นว่างเปล่า พร้อมให้กรอกข้อมูลจริงตั้งแต่วันนี้เป็นต้นไป

---

## ขั้นตอนที่ 2 — สร้างบัญชีผู้ใช้ (เจ้าของ 1 บัญชีเท่านั้น)

ระบบใหม่ใช้อีเมล+รหัสผ่านจริงแทนรหัสผ่านทดลองเดิม สำหรับหน้า "เจ้าของ / แอดมิน" เท่านั้น — พนักงานไม่ต้องมีบัญชี

1. ไปที่เมนู **Authentication → Users** → **Add user** (เลือก "Create new user", ระบุอีเมล+รหัสผ่าน, ติ๊ก "Auto Confirm User")
2. กลับไปที่ **SQL Editor** แล้วรัน (แก้อีเมลให้ตรงกับที่สร้างจริง):

```sql
insert into profiles (id, role, employee_id, display_name)
select id, 'owner', null, 'เจ้าของกิจการ' from auth.users where email = 'owner@yourdomain.com';
```

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

## ขั้นตอนที่ 5 — เชื่อม Cloudflare (Workers static assets)

Cloudflare เปลี่ยน flow ใหม่ — ตอนเชื่อม Git จะให้ตั้งค่าแบบ Workers (ใช้ `wrangler`) แทนหน้า "Pages" แบบเดิม โปรเจกต์นี้มีไฟล์ `wrangler.jsonc` เตรียมไว้ให้แล้ว รองรับ flow ใหม่นี้โดยไม่ต้อง build อะไรเลย

1. เข้า [dash.cloudflare.com](https://dash.cloudflare.com) → **Workers & Pages** → **Create** → เลือกแท็บที่เชื่อม Git ได้ → **Connect to Git**
2. เลือก repo `Ocean-Drinking-water`
3. ตั้งชื่อโปรเจกต์เป็นตัวพิมพ์เล็ก/ตัวเลข/ขีดกลางเท่านั้น เช่น `ocean-drinking-water` (ห้ามมีช่องว่างหรือตัวพิมพ์ใหญ่)
4. ตั้งค่า:
   - **Build command:** เว้นว่างไว้
   - **Deploy command:** ปล่อยเป็น `npx wrangler deploy` ตามค่าเริ่มต้น (ระบบจะอ่านค่าจาก `wrangler.jsonc` ในโปรเจกต์เอง)
5. กด **Deploy**

เว็บจะขึ้นที่ URL แบบ `xxxxx.workers.dev` — เปิดหน้าแรกจะเจอ `index.html` ที่พาไปหน้าแอปหลักอัตโนมัติ ใส่ custom domain เพิ่มได้ในภายหลังจากเมนูของโปรเจกต์นั้น

---

## สรุปลำดับ

| ขั้นตอน | ใครทำ |
|---|---|
| 1. รัน schema.sql + migration-invoices.sql | คุณ (Supabase SQL Editor) |
| 2. สร้างบัญชีเจ้าของ 1 บัญชี + link profile | คุณ (Supabase Dashboard + SQL Editor) |
| 3. ส่ง Project URL + anon key | คุณ → ผม |
| ผมใส่ config + ทดสอบระบบจริง | ผม |
| 4. Push ขึ้น GitHub | คุณ |
| 5. เชื่อม Cloudflare Pages | คุณ |
