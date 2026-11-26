// scripts/ui-verify.mjs reports and does not judge: it prints a result for every test and exits 0. This fails the
// job for every `ok` in the report that is not true, and names where it sits, so a failed run says what failed.
// Usage: node .github/check-ui-verify.mjs ui-verify.json
import { readFileSync } from 'node:fs';

const report = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const checks = [];
(function walk(value, path) {
  if (!value || typeof value !== 'object') return;
  if ('ok' in value) checks.push({ path, ok: value.ok === true, value });
  for (const [key, inner] of Object.entries(value)) walk(inner, path ? `${path}.${key}` : key);
})(report.results, '');

const failed = checks.filter((check) => !check.ok);
for (const { path, value } of failed) console.log(`::error title=ui-verify ${path}::${JSON.stringify(value).slice(0, 1500)}`);
console.log(`ui-verify v${report.verifier}: ${checks.length - failed.length} of ${checks.length} checks passed`);
if (checks.length === 0 || failed.length > 0) process.exit(1);
