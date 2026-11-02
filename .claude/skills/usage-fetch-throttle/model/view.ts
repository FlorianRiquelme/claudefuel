// Statechart view for UsageFetch.tla: one region per statusline.sh run,
// labels in the words of statusline.sh's comments.

const phase: Record<string, string> = {
  idle: "Not started",
  readCache: "Checking cache and backoff files",
  readAttempt: "Checking cache and backoff files",
  readRetry: "Checking cache and backoff files",
  mkdir1: "Taking the fetch lock",
  statLock: "Taking the fetch lock",
  rmLock: "Stealing an old lock",
  mkdir2: "Stealing an old lock",
  touch: "Holding the lock",
  send: "Holding the lock",
  recv: "Request in flight",
  release: "Holding the lock",
  done: "Finished",
};

const runs = (v: any): string[] => Object.keys(v.pc).sort();

export const state = (v: any) =>
  Object.fromEntries(runs(v).map((r) => [`Run ${r}`, phase[v.pc[r]] ?? v.pc[r]]));

export const group = (v: any) =>
  runs(v).filter((r) => ["touch", "send", "recv", "release"].includes(v.pc[r])).length > 1
    ? "two holders"
    : "ok";

export const colors = { "two holders": "orange", ok: "blue" };

export const title = "Usage fetch gate in statusline.sh, two concurrent runs";

const said: Record<string, string> = {
  Start: "the status bar renders",
  ReadCache: "reads the cache file",
  ReadAttempt: "reads the attempt marker",
  ReadRetry: "reads the retry-after file",
  Mkdir1: "mkdir on the lock dir",
  StatLock: "checks the lock's age",
  RmLock: "removes the old lock",
  Mkdir2: "mkdir on the lock dir again",
  Touch: "touches the attempt marker",
  Send: "calls the usage API",
  RecvOk: "the API answers 200",
  Recv429: "the API answers 429",
  RecvError: "the request fails",
  Release: "removes the lock dir",
  Kill: "the run is killed",
  Tick: "a second passes",
  Finished: "all runs finished",
};

export const step = (action: string, from: any, to: any) => {
  const who = runs(from).find((r) => from.pc[r] !== to.pc[r]);
  const what = said[action] ?? action;
  return who ? `${who} ${what}` : what;
};
