// ESM wrapper around the CommonJS entry point. The engine itself is a
// side-effect-free script loaded once by `index.cjs`.

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const api = require("./index.cjs");

export const repair = api.repair;
export const repairResult = api.repairResult;
export const analyze = api.analyze;
export const report = api.report;
export const snapshot = api.snapshot;
export const live = api.live;
export const version = api.version;

export default api;
