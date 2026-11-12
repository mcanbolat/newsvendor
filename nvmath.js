// Newsvendor maths shared by the student page and the dashboard.
// Mirrors the SQL functions in schema.sql (nv_qstar, nv_mean, nv_norm_*).
window.NV = (() => {
  const phi = x => Math.exp(-x * x / 2) / Math.sqrt(2 * Math.PI);
  const Phi = x => {   // Abramowitz & Stegun 7.1.26
    const z = Math.abs(x) / Math.SQRT2, t = 1 / (1 + 0.3275911 * z);
    const e = 1 - (((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t) * Math.exp(-z * z);
    return x >= 0 ? 0.5 * (1 + e) : 0.5 * (1 - e);
  };
  const PhiInv = p => {  // Acklam
    p = Math.min(Math.max(p, 1e-12), 1 - 1e-12);
    if (p < 0.02425) {
      const q = Math.sqrt(-2 * Math.log(p));
      return (((((-7.784894002430293e-03 * q - 3.223964580411365e-01) * q - 2.400758277161838e+00) * q - 2.549732539343734e+00) * q + 4.374664141464968e+00) * q + 2.938163982698783e+00)
           / ((((7.784695709041462e-03 * q + 3.224671290700398e-01) * q + 2.445134137142996e+00) * q + 3.754408661907416e+00) * q + 1);
    }
    if (p <= 1 - 0.02425) {
      const q = p - 0.5, r = q * q;
      return (((((-3.969683028665376e+01 * r + 2.209460984245205e+02) * r - 2.759285104469687e+02) * r + 1.383577518672690e+02) * r - 3.066479806614716e+01) * r + 2.506628277459239e+00) * q
           / (((((-5.447609879822406e+01 * r + 1.615858368580409e+02) * r - 1.556989798598866e+02) * r + 6.680131188771972e+01) * r - 1.328068155288572e+01) * r + 1);
    }
    return -PhiInv(1 - p);
  };
  const n = v => (v === null || v === undefined || v === "") ? null : Number(v);
  const D = s => ({ kind: s.demand_dist || "uniform", a: n(s.demand_min), b: n(s.demand_max),
                    m: n(s.demand_mode), mu: n(s.demand_mean), sd: n(s.demand_sd) });
  const fmt = v => Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 });

  function qstar(s, c) {
    const d = D(s), cr = (n(s.price) - n(c)) / (n(s.price) - n(s.salvage));
    let q;
    if (d.kind === "triangular") {
      q = cr <= (d.m - d.a) / (d.b - d.a) ? d.a + Math.sqrt(cr * (d.b - d.a) * (d.m - d.a))
                                          : d.b - Math.sqrt((1 - cr) * (d.b - d.a) * (d.b - d.m));
    } else if (d.kind === "normal") {
      const pa = Phi((d.a - d.mu) / d.sd), pb = Phi((d.b - d.mu) / d.sd);
      q = d.mu + d.sd * PhiInv(pa + cr * (pb - pa));
    } else q = d.a + cr * (d.b - d.a);
    return Math.round(Math.min(Math.max(q, d.a), d.b));
  }

  function mean(s) {
    const d = D(s);
    if (d.kind === "triangular") return (d.a + d.m + d.b) / 3;
    if (d.kind === "normal") {
      const al = (d.a - d.mu) / d.sd, be = (d.b - d.mu) / d.sd;
      return d.mu + d.sd * (phi(al) - phi(be)) / (Phi(be) - Phi(al));
    }
    return (d.a + d.b) / 2;
  }

  function pdf(s, x) {
    const d = D(s);
    if (x < d.a || x > d.b) return 0;
    if (d.kind === "triangular") return x < d.m ? 2 * (x - d.a) / ((d.b - d.a) * (d.m - d.a) || 1) : 2 * (d.b - x) / ((d.b - d.a) * (d.b - d.m) || 1);
    if (d.kind === "normal") return phi((x - d.mu) / d.sd) / d.sd / (Phi((d.b - d.mu) / d.sd) - Phi((d.a - d.mu) / d.sd));
    return 1 / (d.b - d.a);
  }

  // Plain-language description for students
  function describe(s) {
    const d = D(s);
    if (d.kind === "normal") return {
      short: `Normal, mean ${fmt(d.mu)}, SD ${fmt(d.sd)}`,
      long: `Daily demand is random and bell-shaped (normal), with mean <b>${fmt(d.mu)}</b> and standard deviation <b>${fmt(d.sd)}</b>. It always falls between <b>${d.a}</b> and <b>${d.b}</b>.` };
    if (d.kind === "triangular") return {
      short: `Triangular ${d.a}–${d.b}, peak ${fmt(d.m)}`,
      long: `Daily demand is random with a triangular shape: it falls between <b>${d.a}</b> and <b>${d.b}</b>, and values near <b>${fmt(d.m)}</b> are the most likely.` };
    return { short: `Uniform ${d.a}–${d.b}`,
      long: `Daily demand is random: any whole number from <b>${d.a}</b> to <b>${d.b}</b> is equally likely.` };
  }

  const label = s => ({ uniform: "Uniform", normal: "Normal", triangular: "Triangular" }[D(s).kind]);

  // Small SVG of the demand distribution's shape
  function sketch(s, o = {}) {
    const d = D(s), W = o.w || 320, H = o.h || 110, pad = 14, base = H - 26;
    const xs = Array.from({ length: 81 }, (_, i) => d.a + (d.b - d.a) * i / 80);
    const ys = xs.map(x => pdf(s, x)), top = Math.max(...ys) * 1.15 || 1;
    const X = x => pad + (W - 2 * pad) * (x - d.a) / (d.b - d.a), Y = y => base - (base - 8) * y / top;
    const pts = xs.map((x, i) => `${X(x).toFixed(1)},${Y(ys[i]).toFixed(1)}`).join(" L");
    const mid = d.kind === "triangular" ? d.m : d.kind === "normal" ? d.mu : null;
    const col = o.color || "#b4441c", fill = o.fill || "rgba(180,68,28,.15)", txt = o.text || "#6b645a";
    const t = (x, v, anchor) => `<text x="${X(x).toFixed(1)}" y="${H - 8}" font-size="12" fill="${txt}" text-anchor="${anchor}">${fmt(v)}</text>`;
    return `<svg viewBox="0 0 ${W} ${H}" width="100%" role="img" aria-label="Shape of the demand distribution: ${describe(s).short}" xmlns="http://www.w3.org/2000/svg">
      <path d="M${X(d.a)},${base} L${pts} L${X(d.b)},${base} Z" fill="${fill}" stroke="${col}" stroke-width="2" stroke-linejoin="round"/>
      <line x1="${pad}" y1="${base}" x2="${W - pad}" y2="${base}" stroke="${txt}" stroke-width="1"/>
      ${t(d.a, d.a, "start")}${mid != null ? t(mid, mid, "middle") : ""}${t(d.b, d.b, "end")}</svg>`;
  }

  return { qstar, mean, pdf, describe, label, sketch, Phi, PhiInv };
})();
