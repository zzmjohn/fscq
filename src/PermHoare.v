Require Import Mem Pred.
Require Export PermProgMonad PermPredCrash.
Require Import List.
Require Import Morphisms.
Require Import Word.

Set Implicit Arguments.


(** ** Hoare logic *)

Definition pair_args_helper (A B C:Type) (f: A->B->C) (x: A*B) := f (fst x) (snd x).

Definition donecond (T: Type) := tagged_disk -> block_mem -> T -> Prop.

Definition corr2 (T: Type) pr (pre: donecond T -> @pred _ PeanoNat.Nat.eq_dec valuset -> block_mem ->  @pred _ _ valuset) (p: prog T) :=
  forall d bm tr tr' donec crashc out,
    pre donec crashc bm d
  -> exec pr tr d bm p out tr'
  -> ((exists d' bm' v, out = Finished d' bm' v /\
                  donec d' bm' v) \/
    (exists d', out = Crashed d' /\ crashc d'))/\
    permission_secure d bm pr p.

Notation "{{ pr : pre }} p" := (corr2 pr pre p)
  (at level 0, p at level 60).

Notation "'RET' : r post" :=
  (fun F =>
    (fun r => (F * post)%pred)
  )%pred
  (at level 0, post at level 90, r at level 0, only parsing).

Notation "'RET' : ^( ra , .. , rb ) post" :=
  (fun F =>
    (pair_args_helper (fun ra => ..
      (pair_args_helper (fun rb (_:unit) => (F * post)%pred))
    ..))
  )%pred
  (at level 0, post at level 90, ra closed binder, rb closed binder, only parsing).

(**
  * Underlying CHL that allows pre, post, and crash conditions to state
  * propositions about the hashmap machine state.
  * The pre-hashmap must be a subset of both the post- and crash-hashmaps.
  *)
Notation "{< e1 .. e2 , 'PERM' : pr 'PRE' : pre 'POST' : post >} p1" :=
  (forall T (rx: _ -> prog T), corr2 pr%pred
   ((fun done_ bm =>
    (exis (fun e1 => .. (exis (fun e2 =>
     exists F_,
     F_ * (pre bm) *
     [[ forall r_ ,
        corr2 pr (fun done'_ bm'  =>
           post bm' F_ r_ *
           [[ done'_ = done_ ]])%pred (rx r_) ]]
     )) .. ))
   )%pred)
   (Bind p1 rx)%pred)
  (at level 0, p1 at level 60, right associativity, 
   e1 closed binder, e2 closed binder).


Notation "{< e1 .. e2 , 'PERM' : pr 'PRE' : bm pre 'POST' : bm' post 'CRASH' : crash >} p1" :=
  (forall T (rx: _ -> prog T), corr2 pr%pred
   (fun done_ crash_ bm =>
    (exis (fun e1 => .. (exis (fun e2 =>
     exists F_,
     F_ * pre *
     [[ sync_invariant F_ ]] *
     [[ forall r_ , corr2 pr
        (fun done'_ crash'_ bm' =>
           post F_ r_ * [[ done'_ = done_ ]] * [[ crash'_ = crash_ ]])
        (rx r_) ]] *
     [[ (F_ * crash) =p=> crash_ ]]
     )) .. ))
   )%pred
   (Bind p1 rx)%pred)
  (at level 0, p1 at level 60, bm at level 0, bm' at level 0,
    e1 closed binder, e2 closed binder).

Notation "{< 'X' , 'PERM' : pr 'PRE' : pre 'POST' : post >} p1" :=
  (forall T (rx: _ -> prog T), corr2 pr%pred
   ((fun done_ bm =>
     exists F_,
     F_ * (pre bm) *
     [[ forall r_ ,
        corr2 pr (fun done'_ bm'  =>
           post bm' F_ r_ *
           [[ done'_ = done_ ]])%pred (rx r_) ]]
   )%pred) (* Weird scoping problem *)
   (Bind p1 rx)%pred)
  (at level 0, p1 at level 60, right associativity).

Notation "{< 'X' , 'PERM' : pr 'PRE' : bm pre 'POST' : bm' post 'CRASH' : crash >} p1" :=
  (forall T (rx: _ -> prog T), corr2 pr%pred
   (fun done_ crash_ bm =>
     exists F_,
     F_ * pre *
     [[ sync_invariant F_ ]] *
     [[ forall r_ , corr2 pr
        (fun done'_ crash'_ bm' =>
           post F_ r_ * [[ done'_ = done_ ]] * [[ crash'_ = crash_ ]])
        (rx r_) ]] *
     [[ (F_ * crash) =p=> crash_ ]]
   )%pred
   (Bind p1 rx)%pred)
  (at level 0, p1 at level 60, bm at level 0, bm' at level 0).

Theorem pimpl_ok2:
  forall T pr  (pre pre':donecond T -> @pred _ PeanoNat.Nat.eq_dec valuset -> block_mem ->  @pred _ _ valuset) (p: prog T),
  corr2 pr pre' p ->
  (forall done crash bm, pre done crash bm =p=>  pre' done crash bm) ->
  corr2 pr pre p.
Proof.
  unfold corr2; intros.
  eapply H; eauto.
  apply H0; auto.
Qed.

Theorem pimpl_ok2_cont :
  forall T pr (pre pre': donecond T -> @pred _ PeanoNat.Nat.eq_dec valuset -> block_mem ->  @pred _ _ valuset) A (k : A -> prog T) x y,
    corr2 pr pre' (k y) ->
    (forall done crash bm, pre done crash bm  =p=>  pre' done crash bm) ->
    (forall done crash bm, pre done crash bm  =p=> [x = y]) ->
    corr2 pr pre (k x).
Proof.
  unfold corr2; intros.
  edestruct H1; eauto.
  eapply H; eauto.
  apply H0; auto.
Qed.

Theorem pimpl_pre2:
  forall T pr pre' (pre: donecond T -> @pred _ PeanoNat.Nat.eq_dec valuset -> block_mem ->  @pred _ _ valuset) (p: prog T),
    (forall done crash bm, pre done crash bm  =p=>  [corr2 pr (pre' done crash bm) p]) ->
    (forall done crash bm, pre done crash bm  =p=> pre' done crash bm done crash bm) ->
    corr2 pr pre p.
Proof.
  unfold corr2; intros.
  eapply H; eauto.
  apply H0; auto.
Qed.

Theorem pre_false2:
  forall T pr (pre: donecond T -> @pred _ PeanoNat.Nat.eq_dec valuset -> block_mem ->  @pred _ _ valuset) (p: prog T),
    (forall done crash bm, pre done crash bm  =p=>  [False]) ->
    corr2 pr pre p.
Proof.
  unfold corr2; intros; exfalso.
  eapply H; eauto.
Qed.

Theorem corr2_exists:
  forall T R pr pre (p: prog R),
    (forall (a:T), corr2 pr (fun done crash bm => pre done crash bm a) p) ->
    corr2 pr (fun done crash bm => exists a:T, pre done crash bm a)%pred p.
Proof.
  unfold corr2; intros.
  destruct H0.
  eapply H; eauto.
Qed.

Theorem corr2_forall:
    forall T R pr pre (p: prog R),
      corr2 pr (fun done crash bm => exists a:T, pre done crash bm a)%pred p ->
  (forall (a:T), corr2 pr (fun done crash bm => pre done crash bm a) p).
Proof.
  unfold corr2; intros.
  eapply H; eauto.
  exists a; auto.
Qed.

  Theorem corr2_equivalence :
    forall T pr (p p': prog T) pre,
      corr2 pr pre p' ->
      prog_equiv p p' ->
      corr2 pr pre p.
  Proof.
    unfold corr2; intros.
    match goal with
    | [ H: _ ~= _ |- _ ] =>
      edestruct H; eauto
    end.
    edestruct H; eauto.
    intuition.
    eapply security_equivalence; eauto.
    cleanup.
    eapply security_equivalence; eauto.
  Qed.

Ltac monad_simpl_one :=
  match goal with
  | [ |- corr2 _ _ (Bind (Bind _ _) _) ] =>
    eapply corr2_equivalence;
    [ | apply bind_assoc ]
  end.

Ltac monad_simpl := repeat monad_simpl_one.
