---------------------------- MODULE UsageFetch ----------------------------
(***************************************************************************)
(* The usage-API fetch gate in statusline.sh, as run by several Claude     *)
(* Code sessions on one account at once.                                   *)
(*                                                                         *)
(* Each process in Procs is one run of statusline.sh (one status-bar       *)
(* render). A run starts, reads the cache, attempt, and retry-after files, *)
(* takes the mkdir lock (stealing it when it looks abandoned), touches the *)
(* attempt file, calls GET /api/oauth/usage, handles the response, and     *)
(* removes the lock. Each step is one file operation or one network event  *)
(* in the script. Time passes between any two steps (Tick), and a run can  *)
(* die between any two steps (Kill) without removing the lock.             *)
(*                                                                         *)
(* Time is scaled down: MaxAge stands for cache_max_age=300, MaxHold for   *)
(* the 15 passed to claudefuel_try_lock, RetrySecs for a Retry-After       *)
(* longer than cache_max_age. Only their order matters to the races.       *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS Procs,      \* concurrent statusline.sh runs on one account
          MaxAge,     \* cache_max_age (300 s)
          MaxHold,    \* claudefuel_try_lock max_hold (15 s)
          RetrySecs,  \* Retry-After header of a 429
          MaxTime,    \* bound on the clock, for the model checker
          CanKill,    \* TRUE: a run can die mid-script (no EXIT trap)
          Overlap     \* TRUE: runs overlap; FALSE: one run at a time

ASSUME MaxHold < MaxAge /\ MaxAge < RetrySecs

None == -1

Max(a, b) == IF a > b THEN a ELSE b

VARIABLES
    clock,      \* wall clock, `date +%s`
    \* --- files under /tmp/claude: mtime or content, None = absent
    cacheM,     \* statusline-usage-cache-<hash>.json mtime
    attemptM,   \* statusline-usage-attempt-<hash> mtime
    retryDl,    \* statusline-usage-retryafter-<hash> content (epoch)
    lockM,      \* statusline-usage-fetch-<hash>.lock dir mtime
    \* --- locals of each run
    pc,         \* where the run is in the script
    now,        \* $now, captured once near the start of the run
    needs,      \* $needs_refresh
    should,     \* $should_attempt
    \* --- ghosts: what the API server sees, for stating the rules
    serverDl,   \* server-side 429 cooldown end (response time + Retry-After)
    roundAt,    \* time the run touched the attempt file (its fetch round)
    sent,       \* the run sent its request
    inCooldown, \* the run sent its request during the server's cooldown
    lastRound,  \* latest fetch round begun before this run started
    lastDl,     \* latest deadline written before this run started
    beforeDl,   \* the run sent its request before lastDl
    maxDl       \* latest deadline written to the retry-after file so far

vars == <<clock, cacheM, attemptM, retryDl, lockM, pc, now, needs, should,
          serverDl, roundAt, sent, inCooldown, lastRound, lastDl, beforeDl,
          maxDl>>

files  == <<cacheM, attemptM, retryDl, lockM>>
locals == <<now, needs, should>>
ghosts == <<serverDl, roundAt, sent, inCooldown, lastRound, lastDl, beforeDl,
            maxDl>>

Holding == {"touch", "send", "recv", "release"}

Init ==
    /\ clock = 0
    /\ cacheM = None /\ attemptM = None /\ retryDl = None /\ lockM = None
    /\ pc = [p \in Procs |-> "idle"]
    /\ now = [p \in Procs |-> 0]
    /\ needs = [p \in Procs |-> TRUE]
    /\ should = [p \in Procs |-> TRUE]
    /\ serverDl = None
    /\ roundAt = [p \in Procs |-> None]
    /\ sent = [p \in Procs |-> FALSE]
    /\ inCooldown = [p \in Procs |-> FALSE]
    /\ lastRound = [p \in Procs |-> None]
    /\ lastDl = [p \in Procs |-> None]
    /\ beforeDl = [p \in Procs |-> FALSE]
    /\ maxDl = None

Goto(p, from, to) == pc[p] = from /\ pc' = [pc EXCEPT ![p] = to]

LatestRound == LET rs == {roundAt[q] : q \in Procs} IN
               CHOOSE r \in rs : \A s \in rs : r >= s

\* now=$(date +%s)
Start(p) ==
    /\ Overlap \/ \A q \in Procs : pc[q] \in {"idle", "done"}
    /\ Goto(p, "idle", "readCache")
    /\ now' = [now EXCEPT ![p] = clock]
    /\ lastRound' = [lastRound EXCEPT ![p] = LatestRound]
    /\ lastDl' = [lastDl EXCEPT ![p] = maxDl]
    /\ UNCHANGED <<clock, files, needs, should, serverDl, roundAt, sent,
                   inCooldown, beforeDl, maxDl>>

\* if [ -f "$cache_file" ] ... [ "$cache_age" -lt "$cache_max_age" ] && needs_refresh=false
ReadCache(p) ==
    /\ Goto(p, "readCache", "readAttempt")
    /\ needs' = [needs EXCEPT ![p] = ~(cacheM # None /\ now[p] - cacheM < MaxAge)]
    /\ UNCHANGED <<clock, files, now, should, ghosts>>

\* if [ -f "$attempt_file" ] ... [ "$attempt_age" -lt "$cache_max_age" ] && should_attempt=false
ReadAttempt(p) ==
    /\ Goto(p, "readAttempt", "readRetry")
    /\ should' = [should EXCEPT ![p] = ~(attemptM # None /\ now[p] - attemptM < MaxAge)]
    /\ UNCHANGED <<clock, files, now, needs, ghosts>>

\* if [ -f "$retryafter_file" ] ... [ "$now" -lt "$retry_deadline" ] && should_attempt=false
\* then: if $needs_refresh && $should_attempt && claudefuel_try_lock ...
ReadRetry(p) ==
    LET ok == should[p] /\ ~(retryDl # None /\ now[p] < retryDl)
    IN /\ Goto(p, "readRetry", IF needs[p] /\ ok THEN "mkdir1" ELSE "done")
       /\ UNCHANGED <<clock, files, locals, ghosts>>

\* claudefuel_try_lock: if mkdir "$dir"; then return 0; fi
Mkdir1(p) ==
    /\ Goto(p, "mkdir1", IF lockM = None THEN "touch" ELSE "statLock")
    /\ lockM' = IF lockM = None THEN clock ELSE lockM
    /\ UNCHANGED <<clock, cacheM, attemptM, retryDl, locals, ghosts>>

\* m=$(stat ... "$dir"); [ -n "$m" ] && [ $(( lock_now - m )) -gt "$max_hold" ]
StatLock(p) ==
    /\ Goto(p, "statLock",
            IF lockM # None /\ now[p] - lockM > MaxHold THEN "rmLock" ELSE "done")
    /\ UNCHANGED <<clock, files, locals, ghosts>>

\* rm -rf "$dir"   (steal: removes whatever lock dir is there now)
RmLock(p) ==
    /\ Goto(p, "rmLock", "mkdir2")
    /\ lockM' = None
    /\ UNCHANGED <<clock, cacheM, attemptM, retryDl, locals, ghosts>>

\* mkdir "$dir" 2>/dev/null && return 0
Mkdir2(p) ==
    /\ Goto(p, "mkdir2", IF lockM = None THEN "touch" ELSE "done")
    /\ lockM' = IF lockM = None THEN clock ELSE lockM
    /\ UNCHANGED <<clock, cacheM, attemptM, retryDl, locals, ghosts>>

\* touch "$attempt_file"
Touch(p) ==
    /\ Goto(p, "touch", "send")
    /\ attemptM' = clock
    /\ roundAt' = [roundAt EXCEPT ![p] = clock]
    /\ UNCHANGED <<clock, cacheM, retryDl, lockM, locals, serverDl, sent,
                   inCooldown, lastRound, lastDl, beforeDl, maxDl>>

\* token=$(get_oauth_token); response=$(curl ... /api/oauth/usage)
\* The token lookup is folded in: Tick can pass time before this step.
Send(p) ==
    /\ Goto(p, "send", "recv")
    /\ sent' = [sent EXCEPT ![p] = TRUE]
    /\ inCooldown' = [inCooldown EXCEPT ![p] = serverDl # None /\ clock < serverDl]
    /\ beforeDl' = [beforeDl EXCEPT ![p] = lastDl[p] # None /\ clock < lastDl[p]]
    /\ UNCHANGED <<clock, files, locals, serverDl, roundAt, lastRound, lastDl,
                   maxDl>>

\* 200 with five_hour/seven_day:
\*   echo "$response" > "$cache_file"; rm -f "$retryafter_file"
\* The server answers 200 only to a request sent outside its cooldown.
RecvOk(p) ==
    /\ ~inCooldown[p]
    /\ Goto(p, "recv", "release")
    /\ cacheM' = clock
    /\ retryDl' = None
    /\ UNCHANGED <<clock, attemptM, lockM, locals, ghosts>>

\* 429: echo $(( now + retry_secs )) > "$retryafter_file"
\* The server counts Retry-After from when it answers.
Recv429(p) ==
    /\ Goto(p, "recv", "release")
    /\ retryDl' = now[p] + RetrySecs
    /\ maxDl' = Max(maxDl, now[p] + RetrySecs)
    /\ serverDl' = Max(serverDl, clock + RetrySecs)
    /\ UNCHANGED <<clock, cacheM, attemptM, lockM, locals, roundAt, sent,
                   inCooldown, lastRound, lastDl, beforeDl>>

\* timeout, 5xx, or a body without five_hour/seven_day: nothing written
RecvError(p) ==
    /\ Goto(p, "recv", "release")
    /\ UNCHANGED <<clock, files, locals, ghosts>>

\* rm -rf "$usage_lock_dir"   (removes whatever lock dir is there now)
Release(p) ==
    /\ Goto(p, "release", "done")
    /\ lockM' = None
    /\ UNCHANGED <<clock, cacheM, attemptM, retryDl, locals, ghosts>>

\* The run dies (Claude Code cancels it, the terminal closes). No trap
\* removes the lock dir.
Kill(p) ==
    /\ CanKill
    /\ pc[p] \notin {"idle", "done"}
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<clock, files, locals, ghosts>>

Tick ==
    /\ clock < MaxTime
    /\ clock' = clock + 1
    /\ UNCHANGED <<files, pc, locals, ghosts>>

Finished ==
    /\ \A p \in Procs : pc[p] = "done"
    /\ UNCHANGED vars

Next ==
    \/ \E p \in Procs : Start(p)
    \/ \E p \in Procs : ReadCache(p)
    \/ \E p \in Procs : ReadAttempt(p)
    \/ \E p \in Procs : ReadRetry(p)
    \/ \E p \in Procs : Mkdir1(p)
    \/ \E p \in Procs : StatLock(p)
    \/ \E p \in Procs : RmLock(p)
    \/ \E p \in Procs : Mkdir2(p)
    \/ \E p \in Procs : Touch(p)
    \/ \E p \in Procs : Send(p)
    \/ \E p \in Procs : RecvOk(p)
    \/ \E p \in Procs : Recv429(p)
    \/ \E p \in Procs : RecvError(p)
    \/ \E p \in Procs : Release(p)
    \/ \E p \in Procs : Kill(p)
    \/ Tick
    \/ Finished

Spec == Init /\ [][Next]_vars

Symmetry == Permutations(Procs)

\* A run's locals stop mattering once it is past the point that reads
\* them; drop them there so TLC does not count dead values as new states.
LocalView(p) ==
    CASE pc[p] \in {"idle", "done"}         -> <<pc[p]>>
      [] pc[p] = "readCache"                -> <<pc[p], now[p]>>
      [] pc[p] = "readAttempt"              -> <<pc[p], now[p], needs[p]>>
      [] pc[p] = "readRetry"                -> <<pc[p], now[p], needs[p], should[p]>>
      [] OTHER                              -> <<pc[p], now[p]>>

View == <<clock, files, [p \in Procs |-> LocalView(p)], ghosts>>

-----------------------------------------------------------------------------
(* Rules. The first three are the promise that the comments in            *)
(* statusline.sh make. The last two are its steady-state part: what holds  *)
(* for a run that starts after an earlier round has left its marks on disk.*)

\* At most one run is between taking the lock and releasing it.
Mutex == Cardinality({p \in Procs : pc[p] \in Holding}) <= 1

\* Any two usage requests come from fetch rounds at least MaxAge apart.
Throttle ==
    \A p, q \in Procs :
        (p # q /\ sent[p] /\ sent[q])
            => (roundAt[p] - roundAt[q] >= MaxAge \/ roundAt[q] - roundAt[p] >= MaxAge)

\* No usage request is sent while the server's 429 cooldown is running.
HonorsCooldown == \A p \in Procs : ~inCooldown[p]

\* A run that starts after an earlier fetch round began does not start its
\* own round within MaxAge of it.
LateThrottle ==
    \A p \in Procs :
        (sent[p] /\ lastRound[p] # None) => roundAt[p] >= lastRound[p] + MaxAge

\* A run that starts after a 429 deadline was written does not send before
\* that deadline.
LateCooldown == \A p \in Procs : ~beforeDl[p]

TypeOK ==
    /\ clock \in 0..MaxTime
    /\ pc \in [Procs -> {"idle", "readCache", "readAttempt", "readRetry",
                         "mkdir1", "statLock", "rmLock", "mkdir2", "touch",
                         "send", "recv", "release", "done"}]
=============================================================================
