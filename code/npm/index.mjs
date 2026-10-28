// ESM wrapper around the CommonJS entry point. The engine itself is a
// side-effect-free script loaded once by `index.cjs`.

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const api = require("./index.cjs");

export const InterJSONError = api.InterJSONError;
export const repair = api.repair;
export const repairResult = api.repairResult;
export const analyze = api.analyze;
export const gate = api.gate;
export const report = api.report;
export const snapshot = api.snapshot;
export const snapshotText = api.snapshotText;
export const live = api.live;
export const readiness = api.readiness;
export const deltas = api.deltas;
export const version = api.version;

export default api;
