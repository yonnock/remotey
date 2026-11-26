// The scripts in this folder act on the running agent and so on this Mac: they move its pointer, bring windows
// forward, or lock it. Each one imports this module first. Imports are evaluated in their order, before the
// script's own code, so without `--live` on the command line this throws before anything else runs: an import
// from a test runner, or a glob over the folder, does nothing.
const script = process.argv[1]?.split('/').at(-1) ?? 'this script';
export const asked = (flag) => process.argv.slice(2).includes(flag);

if (!asked('--live')) {
  throw new Error(`scripts/live/ acts on this Mac's running agent (pointer, windows, lock). Run it on purpose: node scripts/live/${script} --live ...`);
}
