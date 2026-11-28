--------------------------- MODULE IssueLockFixed ---------------------------
(***************************************************************************)
(* Candidate fix for #701, checked against the same properties as         *)
(* IssueLock.tla. Bash 3.2 / BSD-userland implementable.                   *)
(*                                                                         *)
(* Design:                                                                 *)
(*  - The lock is a symlink whose target is the holder:                   *)
(*        ln -s "$holder" "$lock"                                          *)
(*    symlink(2) is atomic and publishes the holder together with the     *)
(*    lock, so an "empty holder" state does not exist (fixes 3, 4).        *)
(*  - Holder update (issue_lock_update_pid):                              *)
(*        ln -s "$new" "$tmp" && mv -f "$tmp" "$lock"    (rename(2))       *)
(*  - Stale reclaim is guarded per observed holder value H:               *)
(*        mkdir "$lock.reap.H"   -> re-read holder -> rm only if still H   *)
(*    While the lock points at H and we hold reap.H, nobody else can      *)
(*    change it: ln -s fails on an existing lock, other reclaimers of H    *)
(*    are excluded, and H itself is dead (fixes 1, 2).                     *)
(*                                                                         *)
(* Assumption: holder values are never reused (session tokens; $$ only    *)
(* transiently). PID reuse would break the re-read check.                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Procs,          \* concurrent acquirers (spawn.sh processes)
    Dead,           \* holder token that is verifiably dead
    StaleAtStart    \* TRUE: a stale lock exists initially

\* Records (not strings/tuples) so that TLC can compare every pair of
\* values: Procs and Dead are model values, comparable with anything.
NoLink == [none |-> TRUE]
Tok(p) == [tok |-> p]                   \* worker session token from backend
Tokens == {Tok(p) : p \in Procs}
Holders == Procs \cup Tokens \cup {Dead}

Labels == {"ln1", "read", "verdict", "guard", "recheck", "rm", "ln2",
           "unguardOk", "unguardFail", "ok", "exited", "fail"}

VARIABLES
    link,       \* symlink target of <issue>.lock, or NoLink
    guards,     \* holder values H for which <issue>.lock.reap.H exists
    seen,       \* holder each acquirer observed (local variable)
    pc

vars == <<link, guards, seen, pc>>

TypeOK ==
    /\ link \in Holders \cup {NoLink}
    /\ guards \subseteq Holders
    /\ seen \in [Procs -> Holders \cup {NoLink}]
    /\ pc \in [Procs -> Labels]

\* spawn.sh's $$ is alive until it exits (after the holder update, or on
\* failure). Worker session tokens stay alive (no Worker exit in scope).
Alive(h) ==
    \/ h \in Tokens
    \/ h \in Procs /\ pc[h] \notin {"exited", "fail"}

Init ==
    /\ link = IF StaleAtStart THEN Dead ELSE NoLink
    /\ guards = {}
    /\ seen = [p \in Procs |-> NoLink]
    /\ pc = [p \in Procs |-> "ln1"]

Goto(p, l) == pc' = [pc EXCEPT ![p] = l]

\* ln -s "$$" "$lock"   -- fails if the lock exists
Ln1(p) ==
    /\ pc[p] = "ln1"
    /\ IF link = NoLink
         THEN link' = p /\ Goto(p, "ok")
         ELSE UNCHANGED link /\ Goto(p, "read")
    /\ UNCHANGED <<guards, seen>>

\* holder=$(readlink "$lock") || { retry from ln1 }   -- never empty
Read(p) ==
    /\ pc[p] = "read"
    /\ IF link = NoLink
         THEN UNCHANGED seen /\ Goto(p, "ln1")
         ELSE seen' = [seen EXCEPT ![p] = link] /\ Goto(p, "verdict")
    /\ UNCHANGED <<link, guards>>

\* _issue_lock_holder_alive "$holder"
Verdict(p) ==
    /\ pc[p] = "verdict"
    /\ Goto(p, IF Alive(seen[p]) THEN "fail" ELSE "guard")
    /\ UNCHANGED <<link, guards, seen>>

\* mkdir "$lock.reap.$holder"   -- fails if another reclaimer of H is active
Guard(p) ==
    /\ pc[p] = "guard"
    /\ IF seen[p] \notin guards
         THEN guards' = guards \cup {seen[p]} /\ Goto(p, "recheck")
         ELSE UNCHANGED guards /\ Goto(p, "fail")
    /\ UNCHANGED <<link, seen>>

\* [[ "$(readlink "$lock")" == "$holder" ]]
Recheck(p) ==
    /\ pc[p] = "recheck"
    /\ Goto(p, IF link = seen[p] THEN "rm" ELSE "unguardFail")
    /\ UNCHANGED <<link, guards, seen>>

\* rm -f "$lock"
Rm(p) ==
    /\ pc[p] = "rm"
    /\ link' = NoLink
    /\ Goto(p, "ln2")
    /\ UNCHANGED <<guards, seen>>

\* ln -s "$$" "$lock"
Ln2(p) ==
    /\ pc[p] = "ln2"
    /\ IF link = NoLink
         THEN link' = p /\ Goto(p, "unguardOk")
         ELSE UNCHANGED link /\ Goto(p, "unguardFail")
    /\ UNCHANGED <<guards, seen>>

\* rmdir "$lock.reap.$holder"; return 0 / return 1
Unguard(p, from, to) ==
    /\ pc[p] = from
    /\ guards' = guards \ {seen[p]}
    /\ Goto(p, to)
    /\ UNCHANGED <<link, seen>>

\* spawn.sh: issue_lock_update_pid with the worker token, then exit.
\*   ln -s "$token" "$tmp" && mv -f "$tmp" "$lock"
UpdateAndExit(p) ==
    /\ pc[p] = "ok"
    /\ link' = Tok(p)
    /\ Goto(p, "exited")
    /\ UNCHANGED <<guards, seen>>

Next ==
    \E p \in Procs :
        \/ Ln1(p) \/ Read(p) \/ Verdict(p) \/ Guard(p) \/ Recheck(p)
        \/ Rm(p) \/ Ln2(p)
        \/ Unguard(p, "unguardOk", "ok")
        \/ Unguard(p, "unguardFail", "fail")
        \/ UpdateAndExit(p)

Spec == Init /\ [][Next]_vars

\* Acquirers that believe they hold the lock (acquire returned 0).
Owners == {p \in Procs : pc[p] \in {"ok", "exited"}}

\* At most one owner.
MutualExclusion == Cardinality(Owners) <= 1

\* The lock on disk names the owner (rules out "owner without a lock").
LockNamesOwner == \A p \in Owners : link \in {p, Tok(p)}

=============================================================================
