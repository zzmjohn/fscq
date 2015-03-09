Require Import Prog.
Require Import Pred.
Require Import Hoare.
Require Import Word.
Require Import SepAuto.
Require Import BasicProg.
Require Import MemLog.
Require Import Bool.
Require Import GenSep.
Require Import Idempotent.
Require Import FSLayout.

Set Implicit Arguments.

Definition inc_two T s0 s1 rx : prog T :=
  v0 <- Read s0 ;
  Write s0 (v0 ^+ $1) ;;
  v1 <- Read s1 ;
  Write s1 (v1 ^+ $1) ;;
  rx tt.

Theorem inc_two_ok: forall s0 s1,
  {< v0 v1,
  PRE    s0 |~> v0 * s1 |~> v1
  POST:r s0 |~> (v0 ^+ $1) * s1 |~> (v1 ^+ $1)
  CRASH  s0 |~> v0 * s1 |~> v1 \/
         s0 |~> (v0 ^+ $1) * s1 |~> v1 \/
         s0 |~> (v0 ^+ $1) * s1 |~> (v1 ^+ $1)
  >} inc_two s0 s1.
Proof.
  unfold inc_two.
  hoare.
Qed.

Definition log_inc_two_body T xp s0 s1 mscs rx : prog T :=
  let2 (mscs, v0) <- MEMLOG.read xp s0 mscs;
  mscs <- MEMLOG.write xp s0 (v0 ^+ $1) mscs;
  let2 (mscs, v1) <- MEMLOG.read xp s1 mscs;
  mscs <- MEMLOG.write xp s1 (v1 ^+ $1) mscs;
  rx mscs.

Theorem log_inc_two_body_ok: forall xp s0 s1 mscs,
  {< mbase m v0 v1 F,
  PRE             MEMLOG.rep xp (ActiveTxn mbase m) mscs * 
                  [[ (s0 |-> v0 * s1 |-> v1 * F)%pred (list2mem m)]]
  POST:mscs'      exists m', MEMLOG.rep xp (ActiveTxn mbase m') mscs' *
                  [[ (s0 |-> (v0 ^+ $1) * s1 |-> (v1 ^+ $1) * F)%pred (list2mem m') ]]
  CRASH           MEMLOG.would_recover_old xp mbase
  >} log_inc_two_body xp s0 s1 mscs.
Proof.
  unfold log_inc_two_body.
  hoare_unfold MEMLOG.log_intact_unfold.
Qed.

Hint Extern 1 ({{_}} progseq (log_inc_two_body _ _ _ _) _) => apply log_inc_two_body_ok : prog.

Definition log_inc_two T xp s0 s1 cs rx : prog T :=
  mscs <- MEMLOG.begin xp cs;
  mscs <- log_inc_two_body xp s0 s1 mscs;
  let2 (mscs, ok) <- MEMLOG.commit xp mscs;
  If (bool_dec ok true) {
    rx (mscs, ok)
  } else {
    rx (mscs, false)
  }.

Theorem log_inc_two_ok: forall xp s0 s1 mscs,
  {< mbase v0 v1 F,
  PRE             MEMLOG.rep xp (NoTransaction mbase) mscs * 
                  [[ (s0 |-> v0 * s1 |-> v1 * F)%pred (list2mem mbase)]]
  POST:(mscs', r) [[ r = false ]] * MEMLOG.rep xp (NoTransaction mbase) mscs' \/
                  [[ r = true ]] * exists m', MEMLOG.rep xp (NoTransaction m') mscs' *
                  [[ (s0 |-> (v0 ^+ $1) * s1 |-> (v1 ^+ $1) * F)%pred (list2mem m') ]]
  CRASH           MEMLOG.would_recover_old xp mbase \/
                  exists m', MEMLOG.would_recover_either xp mbase m' *
                  [[ (s0 |-> (v0 ^+ $1) * s1 |-> (v1 ^+ $1) * F)%pred (list2mem m') ]]
  >} log_inc_two xp s0 s1 mscs.
Proof.
  unfold log_inc_two.
  hoare_unfold MEMLOG.log_intact_unfold.
Qed.

Hint Extern 1 ({{_}} progseq (log_inc_two _ _ _ _) _) => apply log_inc_two_ok : prog.

Hint Rewrite crash_xform_sep_star_dist crash_xform_or_dist crash_xform_exists_comm : crash_xform.

Definition i2 xp s0 s1 T := @log_inc_two T xp s0 s1.

Theorem log_inc_two_recover_ok: forall xp s0 s1 mscs cachesize,
  {< v0 v1 F mbase,
  PRE             [[ cachesize <> 0 ]] *
                  MEMLOG.rep xp (NoTransaction mbase) mscs * 
                  [[ (s0 |-> v0 * s1 |-> v1 * F)%pred (list2mem mbase)]]
  POST:(mscs', r) [[ r = false ]] * MEMLOG.rep xp (NoTransaction mbase) mscs' \/
                  [[ r = true ]] * exists m', MEMLOG.rep xp (NoTransaction m') mscs' *
                  [[ (s0 |-> (v0 ^+ $1) * s1 |-> (v1 ^+ $1) * F)%pred (list2mem m') ]]
  CRASH:r         MEMLOG.rep (snd r).(FSXPMemLog) (NoTransaction mbase) (fst r) \/
                  exists m', MEMLOG.rep (snd r).(FSXPMemLog) (NoTransaction m') (fst r) *
                  [[ (s0 |-> (v0 ^+ $1) * s1 |-> (v1 ^+ $1) * F)%pred (list2mem m') ]]
  >} log_inc_two xp s0 s1 mscs >> MEMLOG.recover cachesize.
Proof.
  intros.
  unfold forall_helper at 1 2; intros v0 v1 F.
  eapply (MEMLOG.recover_corr2_to_corr3 (i2 xp s0 s1)).
  unfold i2.
  intros.
  eapply pimpl_ok2.
  eapply log_inc_two_ok.
  cancel.
Qed.
