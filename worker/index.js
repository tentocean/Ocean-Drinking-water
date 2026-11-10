// OCEAN Drinking Water — Worker for the /api/* routes.
//
// The site itself is still plain static files (wrangler.toml [assets]).
// Cloudflare serves a matching file first and only calls this Worker when no
// file matches, so every existing page behaves exactly as before. Anything
// that isn't one of the routes below is handed back to the assets binding.
//
// GET /api/export/oem-orders
//   Every customer in the "OEM / ETC" route plus each one's full sales history,
//   in one call — for the order-cycle forecast that syncs into Notion.
//
//   Auth: header  `Authorization: Bearer <EXPORT_API_KEY>`  (or `X-API-Key: <key>`).
//   EXPORT_API_KEY is a Worker secret (wrangler secret put EXPORT_API_KEY) —
//   never in the code or in wrangler.toml. If it isn't set, the endpoint
//   refuses every request rather than running open.
//
//   Optional query: ?from=YYYY-MM-DD&to=YYYY-MM-DD  (filter orders by sale date)
//
// Dates are the real (Christian-era) ISO dates exactly as stored in
// sales.sale_date, e.g. "2026-10-05" — never Buddhist-era years.

// Same keys/labels as TYPES in ระบบจัดการลูกค้าน้ำดื่ม.dc.html
const PRODUCT_LABELS = {
  '18.9L': 'ถัง 18.9 ลิตร',
  emptytank: 'ถังเปล่า',
  '1500ml': 'แพ็ค 1500ml',
  '600ml': 'แพ็ค 600ml',
  '500ml': 'แพ็ค 500ml',
  '350ml': 'แพ็ค 350ml',
  coupon: 'คูปอง 1 เล่ม (30 ใบ)',
};

const PAGE = 1000; // PostgREST's default max rows per request

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/api/export/oem-orders' || url.pathname === '/api/export/oem-orders/') {
      if (request.method !== 'GET') return json({ error: 'method_not_allowed' }, 405, { Allow: 'GET' });
      const denied = await checkAuth(request, env);
      if (denied) return denied;
      try {
        return json(await exportOemOrders(env, url.searchParams));
      } catch (err) {
        if (err instanceof BadRequest) return json({ error: 'bad_request', message: err.message }, 400);
        console.error('oem-orders export failed', err);
        return json({ error: 'export_failed' }, 502);
      }
    }

    if (url.pathname.startsWith('/api/')) return json({ error: 'not_found' }, 404);

    // Not an API route: behave as if the Worker weren't here.
    return env.ASSETS ? env.ASSETS.fetch(request) : new Response('Not found', { status: 404 });
  },
};

class BadRequest extends Error {}

// ---------------------------------------------------------------- auth

async function checkAuth(request, env) {
  const expected = env.EXPORT_API_KEY;
  if (!expected) {
    // Fail closed: no secret configured means nobody gets in.
    return json({ error: 'export_not_configured' }, 503);
  }
  const header = request.headers.get('Authorization') || '';
  const given = header.startsWith('Bearer ') ? header.slice(7).trim() : (request.headers.get('X-API-Key') || '').trim();
  if (!given || !(await sameSecret(given, expected))) {
    return json({ error: 'unauthorized' }, 401, { 'WWW-Authenticate': 'Bearer' });
  }
  return null;
}

// Constant-time comparison: hash both sides to fixed-length digests, then
// compare every byte so the response time doesn't leak how much matched.
async function sameSecret(a, b) {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(a)),
    crypto.subtle.digest('SHA-256', enc.encode(b)),
  ]);
  const x = new Uint8Array(da), y = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

// ---------------------------------------------------------------- export

async function exportOemOrders(env, params) {
  const from = dateParam(params, 'from');
  const to = dateParam(params, 'to');
  if (from && to && from > to) throw new BadRequest('`from` must be on or before `to`');

  const db = supabaseClient(env);

  // The OEM group is a route (employees row "OEM / ETC", id e4). Look it up by
  // name instead of hard-coding the id, so a renamed/added OEM route still counts.
  const employees = await db.all('employees', 'select=id,name,route&or=(name.ilike.*OEM*,route.ilike.*OEM*)&order=id');
  if (!employees.length) return emptyResult(from, to, []);
  const empIds = employees.map(e => e.id);

  const customers = await db.all(
    'customers',
    `select=id,name,invoice_name,phone,address,tax_id,employee_id&employee_id=in.(${empIds.map(quote).join(',')})&order=name,id`,
  );
  if (!customers.length) return emptyResult(from, to, employees);

  // Every sale of those customers, whoever keyed it — same as the customer
  // detail page, which filters sales by customer only.
  let salesFilter = '';
  if (from) salesFilter += `&sale_date=gte.${from}`;
  if (to) salesFilter += `&sale_date=lte.${to}`;
  const sales = [];
  for (const ids of chunks(customers.map(c => c.id), 100)) {
    sales.push(...await db.all(
      'sales',
      `select=id,group_id,sale_date,customer_id,employee_id,type,qty,price,total,method,paid,paid_date,created_at` +
      `&customer_id=in.(${ids.join(',')})${salesFilter}&order=sale_date,created_at,id`,
    ));
  }

  const byCustomer = new Map(customers.map(c => [c.id, []]));
  for (const s of sales) byCustomer.get(s.customer_id)?.push(s);
  const empName = new Map(employees.map(e => [e.id, e.name]));

  let orderLines = 0;
  const out = customers.map(c => {
    const rows = byCustomer.get(c.id) || [];
    orderLines += rows.length;
    const orders = rows.map(s => ({
      date: s.sale_date,                 // ISO YYYY-MM-DD, Christian era
      bill_id: s.group_id,               // lines keyed together in one sale share this
      product: PRODUCT_LABELS[s.type] || s.type,
      product_key: s.type,
      qty: num(s.qty),
      unit_price: num(s.price),
      amount: num(s.total),
      payment_status: s.paid ? 'paid' : 'unpaid',
      payment_method: s.paid ? s.method : 'credit', // cash | transfer | credit (= ค้างชำระ)
      paid_date: s.paid ? s.paid_date : null,
    }));
    const total = sum(orders.map(o => o.amount));
    const outstanding = sum(orders.filter(o => o.payment_status === 'unpaid').map(o => o.amount));
    const dates = [...new Set(orders.map(o => o.date))];
    return {
      customer_id: c.id,
      customer_name: c.name,
      invoice_name: c.invoice_name || null,
      phone: c.phone || null,
      route: empName.get(c.employee_id) || c.employee_id,
      summary: {
        order_lines: orders.length,           // = "จำนวนรายการ" on the customer page
        bills: new Set(orders.map(o => o.bill_id)).size,
        order_days: dates.length,             // distinct dates with an order
        total_amount: total,                  // = "ยอดซื้อรวม"
        outstanding_amount: outstanding,      // = "ค้างชำระ"
        first_order_date: dates[0] || null,
        last_order_date: dates[dates.length - 1] || null,
      },
      orders,
    };
  });

  return {
    generated_at: new Date().toISOString(),
    group: employees.map(e => e.name).join(', '),
    filter: { from, to },
    customer_count: out.length,
    order_line_count: orderLines,
    customers: out,
  };
}

function emptyResult(from, to, employees) {
  return {
    generated_at: new Date().toISOString(),
    group: employees.map(e => e.name).join(', '),
    filter: { from, to },
    customer_count: 0,
    order_line_count: 0,
    customers: [],
  };
}

// ---------------------------------------------------------------- supabase

function supabaseClient(env) {
  const base = (env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = env.SUPABASE_KEY;
  if (!base || !key) throw new Error('SUPABASE_URL / SUPABASE_KEY not configured');
  const headers = { apikey: key, Authorization: `Bearer ${key}`, Accept: 'application/json' };

  return {
    // Reads every row, a page at a time (PostgREST caps a response at 1000 rows).
    async all(table, query) {
      const rows = [];
      for (let start = 0; ; start += PAGE) {
        const res = await fetch(`${base}/rest/v1/${table}?${query}`, {
          headers: { ...headers, 'Range-Unit': 'items', Range: `${start}-${start + PAGE - 1}` },
        });
        if (!res.ok) throw new Error(`supabase ${table} ${res.status}: ${(await res.text()).slice(0, 300)}`);
        const page = await res.json();
        rows.push(...page);
        if (page.length < PAGE) return rows;
      }
    },
  };
}

// ---------------------------------------------------------------- helpers

function dateParam(params, name) {
  const v = params.get(name);
  if (v == null || v === '') return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v) || isNaN(Date.parse(v + 'T00:00:00Z'))) {
    throw new BadRequest(`\`${name}\` must be YYYY-MM-DD (Christian-era year)`);
  }
  return v;
}

function quote(v) { return `"${String(v).replace(/["\\]/g, '\\$&')}"`; }
function chunks(arr, n) { const r = []; for (let i = 0; i < arr.length; i += n) r.push(arr.slice(i, i + n)); return r; }
function num(v) { return v == null ? null : Number(v); }
function sum(xs) { return Math.round(xs.reduce((a, b) => a + b, 0) * 100) / 100; }

function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      ...extra,
    },
  });
}
