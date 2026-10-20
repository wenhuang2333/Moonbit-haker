export type Profile =
  | "permissive"
  | "interactive"
  | "execution"
  | "agent"
  | "strict";

export type Decision =
  | "safe"
  | "cosmetic_repair"
  | "lossy_repair"
  | "ambiguous"
  | "invalid";

export type Exactness = "exact" | "cosmetic" | "lossy";

export interface AnalyzeOptions {
  /** Safety profile. Use `agent` or `execution` before executing arguments. */
  profile?: Profile;
  /** The library's declaration language, e.g. `{!query:string,!limit:integer}`. */
  schema?: string;
  /** A JSON Schema subset; takes precedence over `schema`. */
  schemaJson?: object | string;
}

export interface RepairRecord {
  rule: string;
  name: string;
  action: string;
  offset: number;
  line: number;
  column: number;
  severity: "info" | "warning";
  ambiguity: string;
  confidence: string;
  confidence_value: number;
  information_loss: boolean;
}

export interface PlanError {
  code: string;
  message: string;
}

export interface RetryHint {
  code: string;
  prompt: string;
}

export interface Plan {
  decision: Decision;
  label: string;
  exactness: Exactness;
  ambiguous: boolean;
  information_loss: boolean;
  valid_json: boolean;
  normalized: boolean;
  ambiguity: string;
  execution: "allowed" | "blocked";
  executable: boolean;
  syntax_ready_permille: number;
  schema_total: number;
  schema_satisfied: number;
  schema_missing: string[];
  error: PlanError | null;
  repairs: RepairRecord[];
  repairs_truncated: boolean;
  retry: RetryHint | null;
  text: string;
  value: unknown;
}

export interface RepairOutcome {
  text: string;
  exactness: Exactness;
  ambiguous: boolean;
  repairs: RepairRecord[];
  decision: Decision;
  executable: boolean;
  error: PlanError | null;
  retry: RetryHint | null;
}

/** Repair `input`; with `profile: "agent"` a lossy/ambiguous repair throws. */
export function repair(input: string, options?: AnalyzeOptions): string;

/** Repair and return the decision fields too. */
export function repairResult(input: string, options?: AnalyzeOptions): RepairOutcome;

/** The never-throwing decision call: returns the full plan object. */
export function analyze(input: string, options?: AnalyzeOptions): Plan;

/** One line per repair, or `-`. */
export function report(input: string): string;

/** Partial value of the first `upto` code units: `value | state | path`. */
export function snapshot(input: string, upto: number): string;

/** One frame of the streaming view (a JSON object). */
export function live(input: string, upto: number, schema?: string): unknown;

export const version: string;

declare const api: {
  repair: typeof repair;
  repairResult: typeof repairResult;
  analyze: typeof analyze;
  report: typeof report;
  snapshot: typeof snapshot;
  live: typeof live;
  version: string;
};
export default api;
