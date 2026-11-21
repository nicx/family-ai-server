// Small, safe Markdown renderer: escapes all HTML first, then applies a
// limited set of Markdown rules. Links only allow http(s) and mailto.
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

function inline(text) {
  const codes = [];
  let s = text.replace(/`([^`\n]+)`/g, (_, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
  s = esc(s);
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_, alt, url) => safeUrl(url) ? `<img src="${url}" alt="${alt}">` : alt);
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, url) =>
    safeUrl(url) ? `<a href="${url}" target="_blank" rel="noopener noreferrer">${label}</a>` : label);
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, (_, pre, url) => `${pre}<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`);
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/__([^_]+)__/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>").replace(/(^|[\s(])_([^_\s][^_]*)_(?=[\s.,;:!?)]|$)/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(codes[+i])}</code>`);
  return s;
}

function safeUrl(url) {
  const u = url.replace(/&amp;/g, "&");
  return /^(https?:|mailto:|\/api\/files\/)/i.test(u);
}

export function renderMarkdown(src) {
  const lines = (src || "").replace(/\r\n/g, "\n").split("\n");
  let html = "";
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^\s*```\s*([\w+-]*)/);
    if (fence) {
      const buf = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) { buf.push(lines[i]); i++; }
      i++;
      html += `<pre><button class="copy" type="button">Kopieren</button><code data-lang="${esc(fence[1] || "")}">${esc(buf.join("\n"))}</code></pre>`;
      continue;
    }
    if (/^\s*$/.test(line)) { i++; continue; }
    const h = line.match(/^(#{1,4})\s+(.*)$/);
    if (h) { const n = h[1].length; html += `<h${n}>${inline(h[2])}</h${n}>`; i++; continue; }
    if (/^\s*(---|\*\*\*|___)\s*$/.test(line)) { html += "<hr>"; i++; continue; }
    if (/^\s*>/.test(line)) {
      const buf = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) { buf.push(lines[i].replace(/^\s*>\s?/, "")); i++; }
      html += `<blockquote>${renderMarkdown(buf.join("\n"))}</blockquote>`;
      continue;
    }
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      const row = (l) => l.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
      const head = row(line);
      i += 2;
      let body = "";
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        body += "<tr>" + row(lines[i]).map((c) => `<td>${inline(c)}</td>`).join("") + "</tr>";
        i++;
      }
      html += `<table><thead><tr>${head.map((c) => `<th>${inline(c)}</th>`).join("")}</tr></thead><tbody>${body}</tbody></table>`;
      continue;
    }
    const li = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
    if (li) {
      const ordered = /\d/.test(li[2]);
      const items = [];
      while (i < lines.length) {
        const m = lines[i].match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
        if (m) { items.push(m[3]); i++; continue; }
        if (/^\s{2,}\S/.test(lines[i]) && items.length) { items[items.length - 1] += "\n" + lines[i].trim(); i++; continue; }
        break;
      }
      const tag = ordered ? "ol" : "ul";
      html += `<${tag}>${items.map((t) => `<li>${inline(t).replace(/\n/g, "<br>")}</li>`).join("")}</${tag}>`;
      continue;
    }
    const para = [];
    while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^\s*```/.test(lines[i]) && !/^#{1,4}\s/.test(lines[i]) &&
           !/^(\s*)([-*+]|\d+[.)])\s+/.test(lines[i]) && !/^\s*>/.test(lines[i])) {
      para.push(lines[i]); i++;
    }
    html += `<p>${para.map(inline).join("<br>")}</p>`;
  }
  return html;
}
