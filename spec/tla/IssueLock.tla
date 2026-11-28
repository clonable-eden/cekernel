----------------------------- MODULE IssueLock -----------------------------
(***************************************************************************)
(* Slice 1 of the TLA+ PoC (#699): issue_lock_acquire only.               *)
(*                                                                         *)
(* Models scripts/shared/issue-lock.sh issue_lock_acquire (L85-103) at     *)
(* the granularity of one filesystem operation per step, so that any      *)
(* interleaving between concurrent acquirers is explored.                 *)
(*                                                                         *)
(* Scope: acquire only. No release, no Worker state, no slots.            *)
(* Expected: MutualExclusion is violated (#701).                          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Procs,          \* concurrent acquirers (spawn.sh in different Orchestrators)
    Dead,           \* token of a holder that is verifiably dead (not-listed)
    StaleAtStart    \* TRUE: a stale lock exists initially; FALSE: no lock

NoFile == "none"    \* pid file absent
Empty  == ""        \* pid file present but empty (truncated), or `cat` of a
                    \* missing file -- both yield holder_pid=""

Holders == Procs \cup {Dead}

VARIABLES
    lockDir,    \* does <issue>.lock/ exist?
    pidFile,    \* content of <issue>.lock/pid, or NoFile
    seen,       \* holder_pid each acquirer read (local variable)
    pc          \* program counter per acquirer

vars == <<lockDir, pidFile, seen, pc>>

TypeOK ==
    /\ lockDir \in BOOLEAN
    /\ pidFile \in Holders \cup {NoFile, Empty}
    /\ seen \in [Procs -> Holders \cup {Empty}]
    /\ pc \in [Procs -> {"mkdir1", "trunc1", "fill1", "checkPid", "readPid",
                         "verdict", "rmPid", "rmdir", "mkdir2", "trunc2",
                         "fill2", "ok", "fail"}]

\* _issue_lock_holder_alive: acquirers are alive while running; Dead is not;
\* an empty holder is treated as dead (issue-lock.sh L58-60).
Alive(h) == h \in Procs

Init ==
    /\ lockDir = StaleAtStart   \* stale lock left by a crashed Worker, or none
    /\ pidFile = IF StaleAtStart THEN Dead ELSE NoFile
    /\ seen = [p \in Procs |-> Empty]
    /\ pc = [p \in Procs |-> "mkdir1"]

Goto(p, l) == pc' = [pc EXCEPT ![p] = l]

\* L85: if mkdir "$lock_dir"; then
Mkdir1(p) ==
    /\ pc[p] = "mkdir1"
    /\ IF ~lockDir
         THEN lockDir' = TRUE  /\ Goto(p, "trunc1")
         ELSE UNCHANGED lockDir /\ Goto(p, "checkPid")
    /\ UNCHANGED <<pidFile, seen>>

\* L86-87 / L100-101: echo "$$" > pid; return 0
\* `>` is two observable steps: open(O_CREAT|O_TRUNC) then write(2).
\*
\* Truncate: creates/empties the pid file. If the directory was removed
\* meanwhile, the redirect fails, but the function still returns 0
\* (errexit is off inside `if !` in spawn.sh).
Truncate(p, from, to) ==
    /\ pc[p] = from
    /\ IF lockDir
         THEN pidFile' = Empty /\ Goto(p, to)
         ELSE UNCHANGED pidFile /\ Goto(p, "ok")
    /\ UNCHANGED <<lockDir, seen>>

\* Fill: write(2) to the open fd. If the file was unlinked meanwhile the
\* bytes go to the orphaned inode and stay invisible.
\* Approximation: "still Empty" is taken to mean "still our inode".
Fill(p, from) ==
    /\ pc[p] = from
    /\ pidFile' = IF pidFile = Empty THEN p ELSE pidFile
    /\ Goto(p, "ok")
    /\ UNCHANGED <<lockDir, seen>>

\* L92: if [[ -f "$pid_file" ]]
CheckPid(p) ==
    /\ pc[p] = "checkPid"
    /\ Goto(p, IF pidFile # NoFile THEN "readPid" ELSE "fail")
    /\ UNCHANGED <<lockDir, pidFile, seen>>

\* L94: holder_pid=$(cat "$pid_file")   -- may read "" if removed meanwhile
ReadPid(p) ==
    /\ pc[p] = "readPid"
    /\ seen' = [seen EXCEPT ![p] = IF pidFile = NoFile THEN Empty ELSE pidFile]
    /\ Goto(p, "verdict")
    /\ UNCHANGED <<lockDir, pidFile>>

\* L95: if ! _issue_lock_holder_alive "$holder_pid"
\* (claude agents --json round trip: arbitrarily long, modeled as one step)
Verdict(p) ==
    /\ pc[p] = "verdict"
    /\ Goto(p, IF Alive(seen[p]) THEN "fail" ELSE "rmPid")
    /\ UNCHANGED <<lockDir, pidFile, seen>>

\* L97: rm -f "$pid_file"
RmPid(p) ==
    /\ pc[p] = "rmPid"
    /\ pidFile' = NoFile
    /\ Goto(p, "rmdir")
    /\ UNCHANGED <<lockDir, seen>>

\* L98: rmdir "$lock_dir" 2>/dev/null || true   -- succeeds only if empty
Rmdir(p) ==
    /\ pc[p] = "rmdir"
    /\ lockDir' = IF lockDir /\ pidFile = NoFile THEN FALSE ELSE lockDir
    /\ Goto(p, "mkdir2")
    /\ UNCHANGED <<pidFile, seen>>

\* L99: if mkdir "$lock_dir"; then ... else fall through to L106 (return 1)
Mkdir2(p) ==
    /\ pc[p] = "mkdir2"
    /\ IF ~lockDir
         THEN lockDir' = TRUE  /\ Goto(p, "trunc2")
         ELSE UNCHANGED lockDir /\ Goto(p, "fail")
    /\ UNCHANGED <<pidFile, seen>>

Next ==
    \E p \in Procs :
        \/ Mkdir1(p)
        \/ Truncate(p, "trunc1", "fill1")
        \/ Fill(p, "fill1")
        \/ CheckPid(p)
        \/ ReadPid(p)
        \/ Verdict(p)
        \/ RmPid(p)
        \/ Rmdir(p)
        \/ Mkdir2(p)
        \/ Truncate(p, "trunc2", "fill2")
        \/ Fill(p, "fill2")

Spec == Init /\ [][Next]_vars

\* At most one acquirer believes it holds the lock (issue_lock_acquire returned 0).
MutualExclusion == Cardinality({p \in Procs : pc[p] = "ok"}) <= 1

=============================================================================
