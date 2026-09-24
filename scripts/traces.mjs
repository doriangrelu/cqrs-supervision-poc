// Affiche les dernières traces Jaeger d'un service sous forme d'arbre chronologique.
// Usage : node scripts/traces.mjs [service=gateway] [nbTraces=3] [minutes=10]   (ATTRS=1 pour afficher les attributs, OP=<opération> pour filtrer, ex : OP="http post /orders")
const [service = 'gateway', limit = '3', minutes = '10'] = process.argv.slice(2);
const end = new Date();
const start = new Date(end.getTime() - Number(minutes) * 60_000);
const url = new URL('http://localhost:16686/api/v3/traces');
url.searchParams.set('query.service_name', service);
url.searchParams.set('query.start_time_min', start.toISOString());
url.searchParams.set('query.start_time_max', end.toISOString());
url.searchParams.set('query.search_depth', limit);
if (process.env.OP) url.searchParams.set('query.operation_name', process.env.OP);

const res = await fetch(url);
if (!res.ok) {
    console.error(`Jaeger ${res.status} : ${await res.text()}`);
    process.exit(1);
}
const traces = new Map();
for (const rs of (await res.json()).result?.resourceSpans ?? []) {
    const svc = rs.resource.attributes.find(a => a.key === 'service.name')?.value.stringValue;
    for (const ss of rs.scopeSpans) {
        for (const s of ss.spans) {
            if (!traces.has(s.traceId)) traces.set(s.traceId, []);
            traces.get(s.traceId).push({ ...s, svc, start: BigInt(s.startTimeUnixNano), end: BigInt(s.endTimeUnixNano) });
        }
    }
}

for (const [traceId, spans] of traces) {
    const t0 = spans.reduce((m, s) => (s.start < m ? s.start : m), spans[0].start);
    const byId = new Map(spans.map(s => [s.spanId, s]));
    const depth = s => (s.parentSpanId && byId.has(s.parentSpanId) ? 1 + depth(byId.get(s.parentSpanId)) : 0);
    const ms = ns => (Number(ns) / 1e6).toFixed(1).padStart(8);
    console.log(`\nTRACE ${traceId} (${spans.length} spans)`);
    for (const s of spans.sort((a, b) => (a.start < b.start ? -1 : 1))) {
        console.log(`  +${ms(s.start - t0)}ms ${ms(s.end - s.start)}ms  ${'  '.repeat(depth(s))}[${s.svc}] ${s.name}`);
        if (process.env.ATTRS) {
            for (const a of s.attributes ?? []) console.log(`${' '.repeat(30 + 2 * depth(s))}${a.key} = ${Object.values(a.value)[0]}`);
        }
    }
}
