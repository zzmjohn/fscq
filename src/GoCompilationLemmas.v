Require Import Eqdep.
Require Import PeanoNat Plus List.
Require Import Word AsyncDisk Prog ProgMonad BasicProg Pred.
Require Import StringMap.
Require Import GoSemantics GoFacts GoHoare GoSepAuto.
Require Import GoTactics2.

Import ListNotations.

Set Implicit Arguments.


Hint Constructors step fail_step crash_step exec.

Hint Extern 1 (Go.eval _ _ = _) =>
unfold Go.eval.

Hint Extern 1 (Go.step _ (_, Go.Assign _ _) _) =>
  eapply Go.StepAssign.
Hint Constructors Go.step.



Lemma CompileSkip : forall env A,
  EXTRACT Ret tt
  {{ A }}
    Go.Skip
  {{ fun _ => A }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
Qed.


Lemma CompileConst : forall env A var (v : nat),
  EXTRACT Ret v
  {{ var ~>? W * A }}
    var <~const v
  {{ fun ret => var ~> ret * A }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
  eval_expr.
  do 2 eexists.
  intuition eauto.
  pred_solve.

  eval_expr.
  contradiction H1.
  repeat econstructor; eauto.
  eval_expr.
  reflexivity.
Qed.

Lemma CompileRet : forall T {H: GoWrapper T} env A B var (v : T) p,
  EXTRACT Ret v
  {{ A }}
    p
  {{ fun ret => var ~> ret * B }} // env ->
  EXTRACT Ret tt
  {{ A }}
    p
  {{ fun _ => var ~> v * B }} // env.
Proof.
  unfold ProgOk; intros.
  forward_solve.
  - invc H4;
    repeat find_apply_lem_hyp inj_pair2; repeat subst;
    eauto.
    invc H14.
  - invc H0.
    repeat find_apply_lem_hyp inj_pair2; repeat subst.
    invc H10.
  - invc H5.
    repeat find_apply_lem_hyp inj_pair2; repeat subst.
    invc H10.

  Unshelve.
  all: auto.
Qed.

Lemma CompileRet' : forall T {H: GoWrapper T} env A B var (v : T) p,
  EXTRACT Ret tt
  {{ A }}
    p
  {{ fun _ => var ~> v * B }} // env ->
  EXTRACT Ret v
  {{ A }}
    p
  {{ fun ret => var ~> ret * B }} // env.
Proof.
  unfold ProgOk; intros.
  forward_solve.
  - invc H4;
    repeat find_apply_lem_hyp inj_pair2; repeat subst;
    eauto.
    invc H14.
  - invc H0.
    repeat find_apply_lem_hyp inj_pair2; repeat subst.
    invc H10.
  - invc H5.
    repeat find_apply_lem_hyp inj_pair2; repeat subst.
    invc H10.

  Unshelve.
  all: auto.
Qed.

Lemma CompileConst' : forall env A var (v : nat),
  EXTRACT Ret tt
  {{ var ~>? nat * A }}
    var <~const v
  {{ fun _ => var ~> v * A }} // env.
Proof.
  eauto using CompileRet, CompileConst.
Qed.

Import Go.

Inductive Declaration :=
| Decl (T : Type) {Wr: GoWrapper T} {D : DefaultValue T}.

Arguments Decl T {Wr} {D}.

Fixpoint n_tuple_unit n (T : Type) : Type :=
  match n with
  | 0 => unit
  | S n' => n_tuple_unit n' T * T
  end.

Definition decls_pre (decls : list Declaration) (vars : n_tuple_unit (length decls) var) : pred.
  induction decls; simpl in *.
  - exact emp.
  - destruct a.
    exact ((snd vars |-> wrap zeroval * IHdecls (fst vars))%pred).
Defined.

Definition decls_post (decls : list Declaration) (vars : n_tuple_unit (length decls) var) : pred.
  induction decls; simpl in *.
  - exact emp.
  - exact ((snd vars |->? * IHdecls (fst vars))%pred).
Defined.

Lemma decls_pre_impl_post :
  forall decls vars,
    decls_pre decls vars =p=> decls_post decls vars.
Proof.
  induction decls; simpl in *; intros.
  - auto.
  - destruct a.
    cancel. auto.
Qed.
Hint Resolve decls_pre_impl_post : cancel_go_finish.

Hint Extern 0 (okToCancel (decls_pre ?decls ?vars) (decls_post ?decls ?vars)) =>
  apply decls_pre_impl_post.

Local Open Scope map_scope.

Lemma Declare_fail :
  forall env d s t xp,
    Go.exec env (d, s, Go.Declare t xp) Go.Failed ->
    exists var, Go.exec env (d, var ->> Go.default_value t; s,
      (xp var; Go.Undeclare var)%go) Go.Failed /\ VarMap.find var s = None.
Proof.
  intros.
  invc H.
  + invc H0; eauto.
  + exfalso; eauto using can_always_declare.
Qed.

Lemma Undeclare_fail :
  forall env st var,
    Go.exec env (st, Go.Undeclare var) Go.Failed -> False.
Proof.
  intros.
  invc H.
  + repeat inv_exec; auto.
  + contradiction H0. destruct st. repeat econstructor.
Qed.

Lemma CompileDeclare :
  forall env R T {Wr : GoWrapper T} {WrD : DefaultValue T} A B (p : prog R) xp,
    (forall var,
       EXTRACT p
       {{ var ~> zeroval * A }}
         xp var
       {{ fun ret => var |->? * B ret }} // env) ->
    EXTRACT p
    {{ A }}
      Go.Declare wrap_type xp
    {{ fun ret => B ret }} // env.
Proof.
  unfold ProgOk; intros.
  repeat destruct_pair.
  destruct out; intuition try discriminate; simpl in *.
  - find_apply_lem_hyp Declare_fail; repeat deex.

    specialize (H x (r, x ->> Go.default_value wrap_type; l) hm).
    forward H.
    {
      simpl. pred_solve.
    }
    intuition idtac.
    find_apply_lem_hyp Go.ExecFailed_Steps.
    forward_solve.
    find_apply_lem_hyp Go.Steps_Seq.
    forward_solve.

    + find_apply_lem_hyp Go.Steps_ExecFailed; eauto.
      forward_solve.
      cbv [snd Go.is_final]. intuition (subst; eauto).
      forward_solve.

    + exfalso; eauto using Undeclare_fail, Go.Steps_ExecFailed.

  - do 2 inv_exec.
    specialize (H var0 (r, var0 ->> Go.default_value wrap_type; l) hm).
    forward H.
    {
      simpl. pred_solve.
    }
    destruct_pair.
    find_inversion_safe.
    find_eapply_lem_hyp Go.ExecFinished_Steps.
    find_eapply_lem_hyp Go.Steps_Seq.
    forward_solve.
    repeat find_eapply_lem_hyp Go.Steps_ExecFinished.
    invc H4. invc H. invc H5. invc H.
    forward_solve.
    simpl in *.
    repeat eexists; eauto.
    pred_solve.

  - do 2 inv_exec.
    specialize (H var0 (r, var0 ->> Go.default_value wrap_type; l) hm).
    forward H.
    {
      simpl. pred_solve.
    }
    find_inversion_safe.
    find_eapply_lem_hyp Go.ExecCrashed_Steps.
    repeat deex; try discriminate.
    find_eapply_lem_hyp Go.Steps_Seq.
    intuition idtac.
    + repeat deex.
      invc H4.
      eapply Go.Steps_ExecCrashed in H2; eauto.
      simpl in *.
      forward_solve.
    + deex.
      invc H5; [ invc H4 | invc H ].
      invc H6; [ invc H4 | invc H ].
Qed.

Definition many_declares (decls : list Declaration) (xp : n_tuple_unit (length decls) var -> stmt) : stmt.
  induction decls; simpl in *.
  - exact (xp tt).
  - destruct a.
    eapply (Declare wrap_type); intro var.
    apply IHdecls; intro.
    apply xp.
    exact (X, var).
Defined.

Lemma CompileDeclareMany :
  forall env T (decls : list Declaration) xp A B (p : prog T),
    (forall vars : n_tuple_unit (length decls) var,
       EXTRACT p
       {{ decls_pre decls vars * A }}
         xp vars
       {{ fun ret => decls_post decls vars * B ret }} // env) ->
    EXTRACT p
    {{ A }}
      many_declares decls xp
    {{ fun ret => B ret }} // env.
Proof.
  induction decls; simpl; intros.
  - eapply hoare_weaken; [ apply H | cancel_go.. ].
  - destruct a. eapply CompileDeclare; eauto. intros.
    eapply IHdecls. intros.
    eapply hoare_weaken; [ apply H | cancel_go.. ].
Qed.

Lemma CompileVar : forall env A var T (v : T) {H : GoWrapper T},
  EXTRACT Ret v
  {{ var ~> v * A }}
    Go.Skip
  {{ fun ret => var ~> ret * A }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
Qed.

Lemma CompileBind : forall T T' {H: GoWrapper T} env A B (C : T' -> _) v0 p f xp xf var,
  EXTRACT p
  {{ var ~> v0 * A }}
    xp
  {{ fun ret => var ~> ret * B }} // env ->
  (forall (a : T),
    EXTRACT f a
    {{ var ~> a * B }}
      xf
    {{ C }} // env) ->
  EXTRACT Bind p f
  {{ var ~> v0 * A }}
    xp; xf
  {{ C }} // env.
Proof.
  unfold ProgOk.
  intuition subst.

  - find_eapply_lem_hyp Go.ExecFinished_Steps. find_eapply_lem_hyp Go.Steps_Seq.
    intuition; repeat deex; try discriminate.
    find_eapply_lem_hyp Go.Steps_ExecFinished. find_eapply_lem_hyp Go.Steps_ExecFinished.
    forwardauto H0; intuition.
    forwardauto H3; repeat deex.
    specialize (H1 x0).
    forward_solve.

  - find_eapply_lem_hyp Go.ExecCrashed_Steps. repeat deex. find_eapply_lem_hyp Go.Steps_Seq.
    intuition; repeat deex.
    + invc H5. find_eapply_lem_hyp Go.Steps_ExecCrashed; eauto.
      forward_solve.
    + destruct x1. find_eapply_lem_hyp Go.Steps_ExecFinished. find_eapply_lem_hyp Go.Steps_ExecCrashed; eauto.
      forwardauto H0; intuition.
      forwardauto H3; repeat deex.
      specialize (H1 x1).
      forward_solve.

  - find_eapply_lem_hyp Go.ExecFailed_Steps. repeat deex. find_eapply_lem_hyp Go.Steps_Seq.
    intuition; repeat deex.
    + eapply Go.Steps_ExecFailed in H5; eauto.
      forward_solve.
      unfold Go.is_final; simpl; intuition subst.
      contradiction H6. eauto.
      intuition. repeat deex.
      contradiction H6. eauto.
    + destruct x1. find_eapply_lem_hyp Go.Steps_ExecFinished. find_eapply_lem_hyp Go.Steps_ExecFailed; eauto.
      forwardauto H0; intuition.
      forwardauto H4; repeat deex.
      specialize (H1 x1).
      forward_solve.
Qed.


Lemma CompileSeq : forall T T' env A B (C : T -> _) p1 p2 x1 x2,
  EXTRACT p1
  {{ A }}
    x1
  {{ fun _ => B }} // env ->
  EXTRACT p2
  {{ B }}
    x2
  {{ C }} // env ->
  EXTRACT Bind p1 (fun _ : T' => p2)
  {{ A }}
    x1; x2
  {{ C }} // env.
Proof.
  unfold ProgOk.
  intuition subst.

  - find_eapply_lem_hyp ExecFinished_Steps. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex; try discriminate.
    find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFinished.
    (* [forward_solve] is not really good enough *)
    forwardauto H. intuition.
    forwardauto H2. repeat deex.
    forward_solve.

  - find_eapply_lem_hyp ExecCrashed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + invc H4. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forward_solve.
    + destruct x3. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forwardauto H. intuition.
      forwardauto H2. repeat deex.
      forward_solve.

  - find_eapply_lem_hyp ExecFailed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + eapply Steps_ExecFailed in H4; eauto.
      forward_solve.
      unfold is_final; simpl; intuition subst.
      contradiction H5.
      repeat eexists. eauto.
      intuition. repeat deex.
      contradiction H5. eauto.
    + destruct x3. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFailed; eauto.
      forwardauto H. intuition.
      forwardauto H3. repeat deex.
      forward_solve.

  Unshelve.
  all: auto.
Qed.

Lemma CompileBindDiscard : forall T T' env A (B : T' -> _)
  (p : prog T) (f : prog T') xp xf,
  EXTRACT p
  {{ A }}
    xp
  {{ fun _ => A }} // env ->
  EXTRACT f
  {{ A }}
    xf
  {{ B }} // env ->
  EXTRACT Bind p (fun (_ : T) => f)
  {{ A }}
    xp; xf
  {{ B }} // env.
Proof.
  intros.
  eapply CompileSeq; eauto.
Qed.

Lemma CompileBefore : forall T env A B (C : T -> _) p x1 x2,
  EXTRACT Ret tt
  {{ A }}
    x1
  {{ fun _ => B }} // env ->
  EXTRACT p
  {{ B }}
    x2
  {{ C }} // env ->
  EXTRACT p
  {{ A }}
    x1; x2
  {{ C }} // env.
Proof.
  intros.
  eapply extract_equiv_prog with (pr1 := Ret tt;; p).
  eapply bind_left_id.
  eapply CompileSeq; eauto.
Qed.

Lemma CompileAfter : forall T env A B (C : T -> _) p x1 x2,
  EXTRACT p
  {{ A }}
    x1
  {{ B }} // env ->
  (forall r : T,
      EXTRACT Ret tt
      {{ B r }}
        x2
      {{ fun _ => C r }} // env) ->
  EXTRACT p
  {{ A }}
    x1; x2
  {{ C }} // env.
Proof.
  unfold ProgOk.
  intuition subst.

  - find_eapply_lem_hyp ExecFinished_Steps. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex; try discriminate.
    find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFinished.
    (* [forward_solve] is not really good enough *)
    forwardauto H. intuition.
    forwardauto H2. repeat deex.
    forward_solve.
    invc H8; repeat (find_apply_lem_hyp inj_pair2; subst); [ | invc H18 ]; eauto.

  - find_eapply_lem_hyp ExecCrashed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + invc H4. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forward_solve.
    + destruct x3. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecCrashed; eauto.
      forwardauto H. intuition.
      forwardauto H2. repeat deex.
      forward_solve.
      invc H0.
      repeat (find_apply_lem_hyp inj_pair2; subst).
      invc H15.

  - find_eapply_lem_hyp ExecFailed_Steps. repeat deex. find_eapply_lem_hyp Steps_Seq.
    intuition; repeat deex.
    + eapply Steps_ExecFailed in H4; eauto.
      forward_solve.
      unfold is_final; simpl; intuition subst.
      contradiction H5.
      repeat eexists. eauto.
      intuition. repeat deex.
      contradiction H5. eauto.
    + destruct x3. find_eapply_lem_hyp Steps_ExecFinished. find_eapply_lem_hyp Steps_ExecFailed; eauto.
      forwardauto H. intuition.
      forwardauto H3. repeat deex.
      forward_solve.
      invc H10.
      repeat (find_apply_lem_hyp inj_pair2; subst).
      invc H15.

  Unshelve.
  all: auto.
Qed.

Lemma CompileBindRet : forall A B (HA : GoWrapper A)
  vara (a : A) (p : A -> prog B) xp xret X Y Z env,
  EXTRACT (Ret a)
  {{ vara ~>? A * X }}
    xret
  {{ fun ret => vara ~> ret * Y }} // env ->
  EXTRACT (p a)
  {{ vara ~> a * Y }}
    xp
  {{ Z }} // env ->
  EXTRACT (Bind (Ret a) p)
  {{ vara ~>? A * X }}
    xret; xp
  {{ Z }} // env.
Proof.
  intros.
  eapply CompileBefore in H0.
  rewrite bind_left_id.
  eapply H0.
  eapply CompileRet. eapply H.
Qed.

Lemma CompileWeq : forall A (a b : valu) env xa xb retvar avar bvar,
  EXTRACT Ret a
  {{ A }}
    xa
  {{ fun ret => avar ~> ret * A }} // env ->
  (forall (av : valu),
  EXTRACT Ret b
  {{ avar ~> av * A }}
    xb
  {{ fun ret => bvar ~> ret * avar ~> av * A }} // env) ->
  EXTRACT Ret (weq a b)
  {{ A }}
    xa ; xb ; retvar <~ (Var avar = Var bvar)
  {{ fun ret => retvar ~> ret * A }} // env.
Proof.
  unfold ProgOk.
  intuition.
Admitted.

Lemma CompileIf : forall V varb (b : bool)
  (ptrue pfalse : prog V) xptrue xpfalse F G env,
  EXTRACT ptrue
  {{ varb ~> true * F }}
    xptrue
  {{ fun ret => G ret * varb ~>? bool }} // env ->
  EXTRACT pfalse
  {{ varb ~> false * F }}
    xpfalse
  {{ fun ret => G ret * varb ~>? bool }} // env ->
  EXTRACT (if b then ptrue else pfalse)
  {{ varb ~> b * F }}
    If (Var varb) Then xptrue Else xpfalse EndIf
  {{ fun ret => G ret * varb ~>? bool }} // env.
Proof.
  intros. unfold ProgOk.
  inv_exec_progok.
  all : inv_exec; try inv_exec; eval_expr;
    try match goal with
    [ H : context [ProgOk] |- _] =>
      solve [edestruct H; forward_solve; pred_solve]
    end.
  all : contradiction H3;
    repeat eexists; solve [
    eapply StepIfTrue; eval_expr |
    eapply StepIfFalse; eval_expr].
Qed.

Lemma CompileRead :
  forall env F avar vvar (v0 : valu) a,
    EXTRACT Read a
    {{ vvar ~> v0 * avar ~> a * F }}
      DiskRead vvar (Var avar)
    {{ fun ret => vvar ~> ret * avar ~> a * F }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
  {
    eval_expr.
    repeat eexists; eauto.
    pred_solve.
  }
  destruct (r a) as [p|] eqn:H'; eauto.
  destruct p.
  contradiction H1.
  repeat econstructor; eauto.
  all : eval_expr; eauto.
Qed.

Lemma CompileWrite : forall env F avar vvar a v,
  EXTRACT Write a v
  {{ avar ~> a * vvar ~> v * F }}
    DiskWrite (Var avar) (Var vvar)
  {{ fun _ => avar ~> a * vvar ~> v * F }} // env.
Proof.
  unfold ProgOk.
  intros.
  inv_exec_progok.
  {
    eval_expr.
    repeat eexists; eauto.
  }
  destruct (r a) as [p|] eqn:H'; eauto.
  destruct p.
  contradiction H1.
  repeat eexists; eauto.
  econstructor; eauto.
  all : eval_expr; eauto.
Qed.


Lemma CompileAdd :
  forall env F sumvar avar bvar (a b : nat),
    EXTRACT Ret (a + b)
    {{ sumvar ~>? W * avar ~> a * bvar ~> b * F }}
      Modify (ModifyNumOp Plus) (sumvar, avar, bvar)
    {{ fun ret => sumvar ~> ret * avar ~> a * bvar ~> b * F }} // env.
Proof.
  unfold ProgOk; intros.
  destruct_pair; simpl in *.
  inv_exec_progok.
  eval_expr.
  repeat econstructor.
  pred_solve.

  contradiction H1.
  eval_expr.
  repeat econstructor.
  all: eval_expr; [reflexivity].
Qed.

Lemma CompileAddInPlace1 :
  forall env F avar bvar (a b : nat),
    EXTRACT Ret (a + b)
    {{ avar ~> a * bvar ~> b * F }}
      Modify (ModifyNumOp Plus) (avar, avar, bvar)
    {{ fun ret => avar ~> ret * bvar ~> b * F }} // env.
Proof.
  unfold ProgOk; intros.
  destruct_pair; simpl in *.
  inv_exec_progok.
  eval_expr.
  repeat econstructor.
  pred_solve.

  contradiction H1.
  eval_expr.
  repeat econstructor.
  all: eval_expr; [reflexivity].
Qed.

(* TODO: make it unnecessary to have all these separate lemmas *)
Lemma CompileAddInPlace2 :
  forall env F avar bvar (a b : nat),
    EXTRACT Ret (a + b)
    {{ avar ~> a * bvar ~> b * F }}
      Modify (ModifyNumOp Plus) (bvar, avar, bvar)
    {{ fun ret => bvar ~> ret * avar ~> a * F }} // env.
Proof.
  unfold ProgOk; intros.
  destruct_pair; simpl in *.
  inv_exec_progok.
  eval_expr.
  repeat econstructor.
  pred_solve.

  contradiction H1.
  eval_expr.
  repeat econstructor.
  all: eval_expr; [reflexivity].
Qed.

Lemma CompileAppend :
  forall env F T {Wr: GoWrapper T} (lvar vvar : var) (x : T) xs,
  EXTRACT Ret (x :: xs)
  {{ vvar ~> x * lvar ~> xs * F }}
    Modify AppendOp (lvar, vvar)
  {{ fun ret => vvar |-> moved_value (wrap x) * lvar ~> ret * F }} // env.
Proof.
  unfold ProgOk; intros.
  repeat extract_var_val.
  inv_exec_progok.
  - find_apply_lem_hyp inj_pair2; subst.
    simpl in *.
    repeat find_rewrite.
    unfold append_impl, append_impl', update_one, id in *.
    repeat destruct_pair.
    repeat find_inversion_safe.
    simpl in *. subst.
    rewrite ?eq_dec_eq in *.
    repeat find_inversion_safe.
    simpl in *.
    rewrite ?eq_dec_eq in *.
    repeat find_inversion_safe.
    destruct (can_alias wrap_type); simpl in *.
    + rewrite ?eq_dec_eq in *. simpl in *. find_inversion; simpl in *.
      repeat eexists.
      eauto.
      pred_solve.
    + rewrite ?eq_dec_eq in *; simpl in *.
      find_inversion.
      repeat econstructor.
      pred_solve.

  - contradiction H1.
    repeat eexists; econstructor.
    unfold append_impl'. simpl.
    (* TODO: this is a mess *)
    all: unfold sel; simpl; repeat find_rewrite; try reflexivity; repeat (simpl; rewrite eq_dec_eq in * ); try reflexivity.
    simpl.
    rewrite ?eq_dec_eq in *.
    simpl.
    instantiate (1 := ltac:(destruct (can_alias wrap_type))).
    destruct (can_alias wrap_type); simpl in *.
    + rewrite ?eq_dec_eq; reflexivity.
    + reflexivity.
Qed.



Lemma map_add_okToCancel : forall AT AEQ {T} {Wr : GoWrapper T} var m k (v : T),
  (@okToCancel AT AEQ value (var ~> Map.add k v m)
  (var |-> (Val (AddrMap wrap_type) (Here (Map.add k (wrap' v) (Map.map wrap' m))))))%pred.
Proof.
  intros. unfold okToCancel.
  unfold wrap. simpl. repeat f_equal.
  eauto using MapUtils.addrmap_equal_eq,
    MoreAddrMapFacts.map_add_comm,
    MapUtils.AddrMap.MapFacts.Equal_refl.
Qed.

Hint Extern 1 (okToCancel (?var ~> Map.add ?k ?v ?m)
  (?var |-> (Val (AddrMap wrap_type) (Here (Map.add ?k (wrap' ?v) (Map.map wrap' ?m))))))
  => apply map_add_okToCancel.


Lemma map_remove_okToCancel : forall AT AEQ {T} {Wr : GoWrapper T} var m k,
  (@okToCancel AT AEQ value (var ~> Map.remove k m)
  (var |-> (Val (AddrMap wrap_type) (Here (Map.remove k (Map.map wrap' m))))))%pred.
Proof.
  intros. unfold okToCancel.
  unfold wrap. simpl. repeat f_equal.
  eauto using MapUtils.addrmap_equal_eq,
    MoreAddrMapFacts.map_remove_comm,
    MapUtils.AddrMap.MapFacts.Equal_refl.
Qed.

Local Hint Extern 1 (okToCancel (?var ~> Map.remove ?k ?m)
  (?var |-> (Val (AddrMap wrap_type) (Here (Map.remove ?k (Map.map wrap' ?m))))))
  => apply map_remove_okToCancel.


Lemma map_find_some_okToCancel : forall AT AEQ {T} {Wr : GoWrapper T} var m k v,
  Map.find k (Map.map wrap' m) = Some v ->
  (@okToCancel AT AEQ value (var ~> Map.find k m)
  (var |-> Val (Pair Bool wrap_type) (true, v))).
Proof.
  intros. unfold okToCancel, wrap. simpl.
  rewrite MapUtils.AddrMap.MapFacts.map_o in H.
  destruct Map.find; simpl in *; congruence.
Qed.

Lemma map_find_none_okToCancel : forall AT AEQ {T} {Wr : GoWrapper T} var m k,
  Map.find k (Map.map wrap' m) = None ->
  (@okToCancel AT AEQ value (var ~> Map.find k m)
  (var |-> Val (Pair Bool wrap_type) (false, default_value' wrap_type))).
Proof.
  intros. unfold okToCancel, wrap. simpl.
  rewrite MapUtils.AddrMap.MapFacts.map_o in H.
  destruct Map.find; simpl in *; congruence.
Qed.

Local Hint Extern 1 (okToCancel (?var ~> Map.find ?k ?m)
  (?var |-> (Val (Pair Bool wrap_type) (true, ?v))))
  => eapply map_find_some_okToCancel.

Local Hint Extern 1 (okToCancel (?var ~> Map.find ?k ?m)
  (?var |-> (Val (Pair Bool wrap_type) (false, ?v))))
  => eapply map_find_none_okToCancel.


Lemma CompileMapAdd : forall env F T {Wr : GoWrapper T} mvar kvar vvar m k (v : T),
  EXTRACT Ret (Go.Map.add k v m)
  {{ mvar ~> m * kvar ~> k * vvar ~> v * F }}
    Go.Modify Go.MapAdd (mvar, kvar, vvar)
  {{ fun ret => mvar ~> ret * kvar ~> k * vvar |-> moved_value (wrap v) * F }} // env.
Proof.
  unfold ProgOk.
  repeat inv_exec_progok.
  - eval_expr; [ repeat eexists; eauto; pred_solve..].
  - eval_expr.
    repeat (contradiction H1;
    repeat econstructor; eauto;
    [ eval_expr; eauto ..]).
Qed.


Lemma CompileMapRemove : forall env F T {Wr : GoWrapper T} mvar kvar m k,
  EXTRACT Ret (Go.Map.remove k m)
  {{ mvar ~> m * kvar ~> k * F }}
    Go.Modify Go.MapRemove (mvar, kvar)
  {{ fun ret => mvar ~> ret * kvar ~> k * F }} // env.
Proof.
  unfold ProgOk.
  repeat inv_exec_progok.
  - eval_expr; [ repeat eexists; eauto; pred_solve..].
  - eval_expr.
    repeat (contradiction H1;
    repeat econstructor; eauto;
    [ eval_expr; eauto ..]).
Qed.

Lemma CompileMapFind : forall env F T {Wr : GoWrapper T} mvar kvar vvar m k,
  EXTRACT Ret (Go.Map.find k m)
  {{ mvar ~> m * kvar ~> k * vvar ~>? (option T) * F }}
    Go.Modify Go.MapFind (mvar, kvar, vvar)
  {{ fun ret => vvar ~> ret * mvar ~> m * kvar ~> k * F }} // env.
Proof.
  unfold ProgOk.
  repeat inv_exec_progok.
  - eval_expr.
    repeat eexists; eauto. pred_solve.
    repeat eexists; eauto. pred_solve.
  - eval_expr.
    repeat (contradiction H1;
    repeat econstructor;
    [ eval_expr; eauto..]).
Qed.

Lemma map_cardinal_okToCancel : forall AT AEQ {T} {Wr : GoWrapper T} var m,
  (@okToCancel AT AEQ value (var ~> Map.cardinal m)
  (var |-> (Val Num (Here (Map.cardinal (Map.map wrap' m))))))%pred.
Proof.
  intros. unfold okToCancel.
  unfold wrap. simpl. repeat f_equal. unfold id.
  eauto using MapUtils.AddrMap.map_cardinal_map_eq.
Qed.

Local Hint Extern 1 (okToCancel (?var ~> Map.cardinal ?m)
  (?var |-> (Val Num (Here (Map.cardinal (Map.map wrap' ?m))))))
  => apply map_cardinal_okToCancel.

Lemma CompileMapCardinal : forall env F T {Wr : GoWrapper T} mvar m var (v0 : W),
  EXTRACT Ret (Go.Map.cardinal m)
  {{ var ~> v0 * mvar ~> m * F }}
    Go.Modify Go.MapCardinality (mvar, var)
  {{ fun ret => var ~> ret * mvar ~> m * F }} // env.
Proof.
  unfold ProgOk.
  repeat inv_exec_progok.
  - eval_expr.
    repeat eexists; eauto. pred_solve.
  - contradiction H1.
    repeat econstructor; [ eval_expr; eauto..].
Qed.

Lemma map_elements_okToCancel : forall AT AEQ {T} {Wr : GoWrapper T} var m,
  @okToCancel AT AEQ value (var ~> Map.elements m)
  (var |-> Val (Slice (Pair Num wrap_type))
         (Here (map (fun x => (Here (fst x), snd x))
               (Map.elements (Map.map wrap' m))))).
Proof.
  intros.
  unfold okToCancel.
  unfold wrap; simpl wrap. repeat f_equal.
  simpl wrap'. repeat f_equal.
  rewrite MapUtils.AddrMap.map_elements_map_eq.
  rewrite map_map. simpl. reflexivity.
Qed.

Local Hint Extern 1 (okToCancel (?var ~> Map.elements ?k ?m)
  (?var |-> (Val _ (Here (map _ (Map.elements _))))))
  => eapply map_elements_okToCancel : okToCancel.

Local Hint Extern 1 (okToCancel (?var ~> Map.elements _)
  (?var |-> Val _ (Here(map _
   (MapUtils.AddrMap_List.Raw.map wrap' (MapUtils.AddrMap_List.this _))))))
  => eapply map_elements_okToCancel : okToCancel.

Lemma CompileMapElements : forall env F T {Wr : GoWrapper T} mvar m var (v0 : list (W * T)),
  EXTRACT Ret (Go.Map.elements m)
  {{ var ~> v0 * mvar ~> m * F }}
    Go.Modify Go.MapElements (mvar, var)
  {{ fun ret => var ~> ret * mvar ~> m * F }} // env.
Proof.
  unfold ProgOk.
  repeat inv_exec_progok.
  - eval_expr.
    repeat eexists; eauto. pred_solve.
  - eval_expr.
    contradiction H1. repeat econstructor.
    eval_expr. eauto.
    eval_expr. eauto.
    eval_expr. eauto.
Qed.

Lemma CompileForLoopBasic : forall L G (L' : GoWrapper L) v loopvar F
                          (n i : W)
                          t0 term
                          env (pb : W -> L -> prog L) xpb nocrash oncrash,
    (forall t x,
        EXTRACT (pb x t)
  {{ loopvar ~> t * v ~> x * term ~> (i + n) * F }}
    xpb
  {{ fun ret => loopvar ~> ret * v ~> S x * term ~> (i + n) * F }} // env)
  ->
  EXTRACT (@ForN_ L G pb i n nocrash oncrash t0)
  {{ loopvar ~> t0 * v ~> i * term ~> (i + n) * F }}
    Go.While (TestE Lt (Var v) (Var term))
      (xpb)
  {{ fun ret => loopvar ~> ret * v ~> (i + n) * term ~> (i + n) * F }} // env.
Proof.
  induction n; intros; simpl.
  - unfold ProgOk. intros.
    rewrite <- plus_n_O in *.
    repeat destruct_pair.
    inv_exec.
    + inv_exec.
      eval_expr.
      inv_exec_progok.
    + inv_exec_progok.
      contradiction H2.
      repeat eexists.
      eapply StepWhileFalse.
      eval_expr.
    + inv_exec_progok.
  - unfold ProgOk. intros.
    destruct_pairs.
    destruct out.
    + (* failure case *)
      intuition try congruence.
      inv_exec.
      {
        inv_exec; eval_expr.
        find_eapply_lem_hyp ExecFailed_Steps. repeat deex.
        find_eapply_lem_hyp Steps_Seq.
        intuition subst; repeat deex.
        { (* failure in body *)
          eapply Prog.XBindFail.
          repeat destruct_pair.
          edestruct H; eauto.
          2 : eapply Steps_ExecFailed; [> | | eauto].
          pred_solve.
          unfold is_final; simpl; intro; subst; eauto.
          edestruct ExecFailed_Steps.
          eapply Steps_ExecFailed; eauto.
          eapply steps_sequence. eauto.
          repeat deex; eauto.
          intuition eauto.
        }
        { (* failure in loop *)
          find_eapply_lem_hyp Steps_ExecFinished.
          edestruct H; eauto. pred_cancel.
          edestruct H4; eauto. simpl in *; repeat deex.
          destruct_pair; simpl in *.
          edestruct (IHn (S i));
            [> | | eapply Steps_ExecFailed; eauto |];
            rewrite ?plus_Snm_nSm; eauto.
          intuition eauto.
        }
      }
      {
        contradiction H3.
        repeat eexists.
        eapply StepWhileTrue.
        eval_expr.
      }
    + (* finished case *)
      inv_exec. inv_exec; eval_expr. subst_definitions.
      intuition try congruence. repeat find_inversion_safe.
      repeat match goal with
      | [H : context[Init.Nat.add _ (S _)] |- _] =>
          (rewrite <- plus_Snm_nSm in H || setoid_rewrite <- plus_Snm_nSm in H)
      end.
      setoid_rewrite <- plus_Snm_nSm.
      destruct_pairs.
      find_eapply_lem_hyp ExecFinished_Steps.
      find_eapply_lem_hyp Steps_Seq.
      intuition; repeat deex; try discriminate.
      repeat find_eapply_lem_hyp Steps_ExecFinished.
      edestruct H; eauto; eauto.
      forward_solve.
      edestruct (IHn (S i)); eauto.
      forward_solve.
    + (* crashed case *)
      intuition try congruence. find_inversion.
      inv_exec; [> | solve [inversion H3] ].
      inv_exec; eval_expr.
      find_eapply_lem_hyp ExecCrashed_Steps.
      intuition; repeat deex.
      find_eapply_lem_hyp Steps_Seq.
      intuition auto; repeat deex.
      {
        invc H4.
        find_eapply_lem_hyp Steps_ExecCrashed; eauto.
        edestruct H; forward_solve. auto.
      }
      {
        find_eapply_lem_hyp Steps_ExecFinished.
        find_eapply_lem_hyp Steps_ExecCrashed; eauto.
        edestruct H; eauto. pred_cancel.
        repeat match goal with
        | [H : context[Init.Nat.add _ (S _)] |- _] =>
            (rewrite <- plus_Snm_nSm in H || setoid_rewrite <- plus_Snm_nSm in H)
        end.
        edestruct H2; eauto.
        forward_solve.
        repeat deex.
        edestruct IHn; eauto.
        forward_solve.
      }
Qed.


Lemma SetConstBefore : forall T (T' : GoWrapper T) (p : prog T) env xp v n A B,
  EXTRACT p {{ v ~> n * A }} xp {{ B }} // env ->
  EXTRACT p
    {{ v ~>? nat * A }}
      v <~const n; xp
    {{ B }} // env.
Proof.
  eauto using CompileBefore, CompileConst'.
Qed.

Lemma CompileDup : forall env X (Wr : GoWrapper X) F (var var' : var) x,
  EXTRACT Ret x
  {{ var ~> x * var' ~>? X * F }}
    var' <~dup var
  {{ fun ret => var ~> x * var' ~> ret * F }} // env.
Proof.
  unfold ProgOk.
  inv_exec_progok.
  - repeat inv_exec.
    eval_expr.
    repeat econstructor.
    pred_solve.
  - repeat inv_exec.
  - repeat inv_exec.
    + exfalso; eauto.
    + contradiction H1. eval_expr.
      repeat econstructor;
        [ eval_expr; eauto .. ].
Qed.

Lemma DuplicateBefore : forall T (T' : GoWrapper T) X (X' : GoWrapper X)
  (p : prog T) xp env v v' (x x' : X) A B,
  EXTRACT p {{ v ~> x * v' ~> x * A }} xp {{ B }} // env ->
  EXTRACT p
    {{ v ~> x' * v' ~> x * A }}
      v <~dup v'; xp
    {{ B }} // env.
Proof.
  unfold ProgOk.
  inv_exec_progok.
  - do 5 inv_exec. inv_exec.
    eval_expr.
    edestruct H; forward_solve.
    simpl. pred_solve.
  - do 5 inv_exec; try solve [inv_exec].
    eval_expr.
    edestruct H; forward_solve.
    simpl. pred_solve.
  - inv_exec.
    do 3 inv_exec; forward_solve.
    inv_exec. inv_exec.
    eval_expr.
    edestruct H; forward_solve.
    simpl. pred_solve.
    contradiction H2.
    repeat eexists; eauto.
    do 2 econstructor; solve [eval_expr; eauto].
Qed.

Lemma AddInPlaceLeftBefore : forall T (T' : GoWrapper T) (p : prog T) B xp env
  va a v x F,
  EXTRACT p {{ v ~> (x + a) * va ~> a * F }} xp {{ B }} // env ->
  EXTRACT p
  {{ v ~> x * va ~> a * F }}
    Go.Modify (Go.ModifyNumOp Plus) (v, v, va); xp
  {{ B }} // env.
Proof.
  intros.
  eapply CompileBefore; eauto.
  eapply hoare_weaken.
  eapply CompileRet with (T := nat) (var0 := v).
  eapply hoare_weaken_post; [ | eapply CompileAddInPlace1 with (avar := v) (bvar := va) ].
  all : cancel_go.
Qed.

Lemma AddInPlaceLeftAfter : forall T (T' : GoWrapper T) (p : prog T) A xp env
  va a v x F,
  EXTRACT p {{ A }} xp {{ fun ret => F ret * v ~> x * va ~> a }} // env ->
  EXTRACT p
  {{ A }}
    xp; Go.Modify (Go.ModifyNumOp Plus) (v, v, va)
  {{ fun ret => F ret * v ~> (x + a) * va ~> a }} // env.
Proof.
  intros.
  eapply CompileAfter; eauto.
  intros.
  eapply hoare_weaken_post; [ | eapply CompileRet with (var0 := v) (v := x + a) ].
  cancel_go.
  eapply hoare_weaken.
  eapply CompileAddInPlace1 with (avar := v) (bvar := va).
  all: cancel_go.
Qed.

Lemma CompileFor : forall L G (L' : GoWrapper L) loopvar F
                          v vn (n i : W)
                          t0 env (pb : W -> L -> prog L) xpb nocrash oncrash,
    (forall t x v term one,
        EXTRACT (pb x t)
  {{ loopvar ~> t * v ~> x * term ~> (i + n) * one ~> 1 * vn ~> n * F }}
    xpb v term one
  {{ fun ret => loopvar ~> ret * v ~> x * term ~> (i + n) * one ~> 1 * vn ~> n * F }} // env)
  ->
  EXTRACT (@ForN_ L G pb i n nocrash oncrash t0)
  {{ loopvar ~> t0 * v ~> i * vn ~> n * F }}
    Declare Num (fun one => (
      one <~const 1;
      Declare Num (fun term => (
        Go.Modify (Go.DuplicateOp) (term, v);
        Go.Modify (Go.ModifyNumOp Go.Plus) (term, term, vn);
        Go.While (TestE Lt (Var v) (Var term)) (
          xpb v term one;
          Go.Modify (Go.ModifyNumOp Go.Plus) (v, v, one)
        )
      ))
    ))
  {{ fun ret => loopvar ~> ret * v |->? * vn |->? * F }} // env.
Proof.
  intros.
  eapply CompileDeclare with (Wr := GoWrapper_Num). intro one.
  eapply hoare_strengthen_pre; [>
  | eapply SetConstBefore; eauto ].
  cancel_go.
  eapply CompileDeclare with (Wr := GoWrapper_Num). intro term.
  eapply hoare_strengthen_pre; [>
  | eapply DuplicateBefore with (x' := 0) (x := i); eauto].
  cancel_go.
  eapply hoare_strengthen_pre; [>
  | eapply AddInPlaceLeftBefore with (a := n) (x := i); eauto ].
  cancel_go.
  eapply hoare_weaken; [>
    eapply CompileForLoopBasic with (t0 := t0) (loopvar := loopvar)
  | cancel_go..].
  intros.
  eapply hoare_weaken_post; [>
  | eapply AddInPlaceLeftAfter with (a := 1) (x := x); eauto].
  rewrite Nat.add_1_r.
  cancel_go. apply pimpl_refl.
  eapply hoare_weaken; [>
    eapply H | cancel_go..].
Qed.

Definition voidfunc2 A B C {WA: GoWrapper A} {WB: GoWrapper B} name (src : A -> B -> prog C) env :=
  forall avar bvar,
    forall a b F, EXTRACT src a b
           {{ avar ~> a * bvar ~> b * F }}
             Call [] name [avar; bvar]
           {{ fun _ => avar |->? * bvar |->? * F
            (* TODO: could remember a & b if they are of aliasable type *) }} // env.


(* TODO: generalize for all kinds of functions *)
Lemma extract_voidfunc2_call :
  forall A B C {WA: GoWrapper A} {WB: GoWrapper B} name (src : A -> B -> prog C) arga argb arga_t argb_t env,
    forall and body ss,
      (forall a b F, EXTRACT src a b {{ arga ~> a * argb ~> b * F }} body {{ fun _ => arga |->? * argb |->? * F }} // env) ->
      StringMap.find name env = Some {|
                                    ParamVars := [(arga_t, arga); (argb_t, argb)];
                                    RetParamVars := [];
                                    Body := body;
                                    (* ret_not_in_args := rnia; *)
                                    args_no_dup := and;
                                    body_source := ss;
                                  |} ->
      voidfunc2 name src env.
Proof.
  unfold voidfunc2.
  intros A B C WA WB name src arga argb arga_t argb_t env and body ss Hex Henv avar bvar a b F.
  specialize (Hex a b F).
  intro.
  intros.
  intuition subst.
  - find_eapply_lem_hyp ExecFinished_Steps.
    find_eapply_lem_hyp Steps_runsto.
    invc H0.
    find_eapply_lem_hyp runsto_Steps.
    find_eapply_lem_hyp Steps_ExecFinished.
    rewrite Henv in H4.
    find_inversion_safe.
    subst_definitions. unfold sel in *. simpl in *. unfold ProgOk in *.
    repeat eforward Hex.
    forward Hex.
    shelve.
    forward_solve.
    simpl in *.
    do 2 eexists.
    intuition eauto.
    break_match.
    (*
    eauto.

    econstructor.
    econstructor.
  - find_eapply_lem_hyp ExecCrashed_Steps.
    repeat deex.
    invc H1; [ solve [ invc H2 ] | ].
    invc H0.
    rewrite Henv in H7.
    find_inversion_safe. unfold sel in *. simpl in *.
    assert (exists bp', (Go.step env)^* (d, callee_s, body) (final_disk, s', bp') /\ p' = InCall s [arga; argb] [] [avar; bvar] [] bp').
    {
      remember callee_s.
      clear callee_s Heqt.
      generalize H3 H2. clear. intros.
      prep_induction H3; induction H3; intros; subst.
      - find_inversion.
        eauto using rt1n_refl.
      - invc H0.
        + destruct st'.
          forwardauto IHclos_refl_trans_1n; deex.
          eauto using rt1n_front.
        + invc H3. invc H2. invc H.
    }
    deex.
    eapply Steps_ExecCrashed in H1.
    unfold ProgOk in *.
    repeat eforward Hex.
    forward Hex.
    shelve.
    forward_solve.
    invc H2. trivial.
  - find_eapply_lem_hyp ExecFailed_Steps.
    repeat deex.
    invc H1.
    + contradiction H3.
      destruct st'. repeat eexists. econstructor; eauto.
      unfold sel; simpl in *.
      maps.
      find_all_cases.
      trivial.
    + invc H2.
      rewrite Henv in H8.
      find_inversion_safe. simpl in *.
      assert (exists bp', (Go.step env)^* (d, callee_s, body) (st', bp') /\ p' = InCall s [arga; argb] [] [avar; bvar] [] bp').
      {
        remember callee_s.
        clear callee_s Heqt.
        generalize H4 H0 H3. clear. intros.
        prep_induction H4; induction H4; intros; subst.
        - find_inversion.
          eauto using rt1n_refl.
        - invc H0.
          + destruct st'0.
            forwardauto IHclos_refl_trans_1n; deex.
            eauto using rt1n_front.
          + invc H4. contradiction H1. auto. invc H.
      }
      deex.
      eapply Steps_ExecFailed in H2.
      unfold ProgOk in *.
      repeat eforward Hex.
      forward Hex. shelve.
      forward_solve.
      intuition.
      contradiction H3.
      unfold is_final in *; simpl in *; subst.
      destruct st'. repeat eexists. eapply StepEndCall; simpl; eauto.
      intuition.
      contradiction H3.
      repeat deex; eauto.

  Unshelve.
  * simpl in *.
    maps.
    find_all_cases.
    find_inversion_safe.
    maps.
    find_all_cases.
    find_inversion_safe.
    eapply Forall_elements_remove_weaken.
    eapply forall_In_Forall_elements.
    intros.
    destruct (Nat.eq_dec k argb).
    subst. maps. find_inversion_safe.
    find_copy_eapply_lem_hyp NoDup_bool_sound.
    invc H.
    assert (arga <> argb).
    intro. subst. contradiction H2. constructor. auto.
    maps.
    intros. apply sumbool_to_bool_dec.
    maps.
  * (* argh *)
    simpl in *.
    subst_definitions.
    maps.
    find_all_cases.
    find_inversion_safe.
    maps.
    eapply Forall_elements_remove_weaken.
    eapply forall_In_Forall_elements.
    intros.
    destruct (Nat.eq_dec k argb).
    subst. maps. find_inversion_safe.
    find_copy_eapply_lem_hyp NoDup_bool_sound.
    invc H.
    assert (arga <> argb).
    intro. subst. contradiction H8. constructor. auto.
    find_cases avar s.
    find_cases bvar s.
    find_inversion_safe.
    maps.
    intros. apply sumbool_to_bool_dec.
    maps.
  * unfold sel in *; simpl in *.
    subst_definitions.
    simpl in *.
    find_cases avar s.
    find_cases bvar s.
    find_inversion_safe.
    maps.
    rewrite He in *.
    auto.
    eapply Forall_elements_remove_weaken.
    eapply forall_In_Forall_elements.
    intros.
    destruct (Nat.eq_dec k argb).
    subst. maps. find_inversion_safe.
    find_copy_eapply_lem_hyp NoDup_bool_sound.
    invc H.
    assert (arga <> argb).
    intro. subst. contradiction H9. constructor. auto.
    maps.
    rewrite He0 in *. auto.
    intros. apply sumbool_to_bool_dec.
    maps.
*)
Admitted.

Lemma CompileSplit :
  forall env A B {HA: GoWrapper A} {HB: GoWrapper B} avar bvar pvar F (p : A * B),
    EXTRACT Ret tt
    {{ avar ~>? A * bvar ~>? B * pvar ~> p * F }}
      Modify SplitPair (pvar, avar, bvar)
    {{ fun _ => avar ~> fst p * bvar ~> snd p * pvar |-> moved_value (wrap p) * F }} // env.
Proof.
  intros; unfold ProgOk.
  inv_exec_progok.
  - repeat inv_exec.
    eval_expr.
    repeat econstructor.
    pred_solve.
  - inv_exec_progok.
  - inv_exec_progok.
    eval_expr.
    contradiction H1.
    repeat econstructor;
    [ eval_expr; eauto ..].
Qed.

Lemma CompileFst :
  forall env A B {HA: GoWrapper A} {HB: GoWrapper B} avar bvar pvar F (p : A * B),
    EXTRACT Ret (fst p)
    {{ avar ~>? A * bvar ~>? B * pvar ~> p * F }}
      Modify SplitPair (pvar, avar, bvar)
    {{ fun ret => avar ~> ret * bvar ~> snd p * pvar |-> moved_value (wrap p) * F }} // env.
Proof.
  intros; unfold ProgOk.
  inv_exec_progok.
  - repeat inv_exec.
    repeat econstructor.
    eval_expr.
    pred_solve.
  - inv_exec_progok.
  - inv_exec_progok.
    eval_expr.
    contradiction H1.
    repeat econstructor;
    [ eval_expr; eauto ..].
Qed.

Lemma CompileSnd :
  forall env A B {HA: GoWrapper A} {HB: GoWrapper B} avar bvar pvar F (p : A * B),
    EXTRACT Ret (snd p)
    {{ avar ~>? A * bvar ~>? B * pvar ~> p * F }}
      Modify SplitPair (pvar, avar, bvar)
    {{ fun ret => avar ~> fst p * bvar ~> ret * pvar |-> moved_value (wrap p) * F }} // env.
Proof.
  intros; unfold ProgOk.
  inv_exec_progok.
  - repeat inv_exec.
    repeat econstructor.
    eval_expr.
    pred_solve.
  - inv_exec_progok.
  - inv_exec_progok.
    eval_expr.
    contradiction H1.
    repeat econstructor;
    [ eval_expr; eauto ..].
Qed.

Lemma CompileJoin :
  forall env A B {HA: GoWrapper A} {HB: GoWrapper B} avar bvar pvar (a : A) (b : B) F,
    EXTRACT Ret (a, b)
    {{ avar ~> a * bvar ~> b * pvar ~>? (A * B)%type * F }}
      Modify JoinPair (pvar, avar, bvar)
    {{ fun ret => avar |-> moved_value (wrap a) * bvar |-> moved_value (wrap b) * pvar ~> ret * F }} // env.
Proof.
  intros; unfold ProgOk.
  repeat inv_exec_progok.
  - repeat inv_exec.
    eval_expr.
    repeat econstructor.
    pred_solve.
  - contradiction H1.
    eval_expr.
    repeat econstructor.
    eval_expr; eauto.
    eval_expr; eauto.
    eval_expr; eauto.
Qed.

Hint Constructors source_stmt.

Lemma CompileRetOptionSome : forall env B {HB: GoWrapper B} {D : DefaultValue B}
  avar bvar pvar (b : B) (p : bool * B) F,
  EXTRACT Ret (Some b)
  {{ avar ~> true * bvar ~> b * pvar ~> p * F }}
    Modify JoinPair (pvar, avar, bvar)
  {{ fun ret => pvar ~> ret *
                avar |-> moved_value (wrap true) *
                bvar |-> moved_value (wrap b) * F }} // env.
Proof.
  intros.
  unfold ProgOk.
  inv_exec_progok.
  - repeat inv_exec.
    repeat econstructor.
    eval_expr.
    pred_solve.
  - inv_exec_progok.
  - inv_exec_progok.
    contradiction H1.
    repeat econstructor;
    [ eval_expr; eauto..].
Qed.

Lemma option_none_okToCancel : forall AT AEQ {T} {HT : GoWrapper T} {D : DefaultValue T} var,
  @okToCancel AT AEQ value (var ~> None) (var |-> Val (Pair Bool wrap_type) (false, wrap' zeroval)).
Proof.
  intros.
  unfold wrap. simpl.
  rewrite default_zero' by apply default_zero.
  reflexivity.
Qed.

Local Hint Extern 1 (okToCancel (?var ~> None)
  (?var |-> Val (Pair Bool wrap_type) (false, wrap' zeroval)))
  => apply option_none_okToCancel.

Lemma CompileRetOptionNone : forall env B {HB: GoWrapper B} {D : DefaultValue B}
  avar pvar (p : bool * B) F,
  EXTRACT Ret None
  {{ avar ~> false * pvar ~> p * F }}
    Declare wrap_type (fun bvar =>
      Modify JoinPair (pvar, avar, bvar)
    )
  {{ fun ret => pvar ~> ret *
                avar |-> moved_value (wrap false) * F }} // env.
Proof.
  intros.
  eapply CompileDeclare. intro bvar.
  unfold ProgOk.
  inv_exec_progok.
  - repeat inv_exec.
    repeat econstructor.
    eval_expr.
    pred_solve.
    eapply pimpl_apply.
    2: eapply ptsto_upd. 2: pred_apply; cancel_go. cancel_go.
  - inv_exec_progok.
  - inv_exec_progok.
    contradiction H1.
    repeat econstructor;
    [ eval_expr; eauto..].
Qed.

Lemma CompileMatchOption : forall env B {HB : GoWrapper B} X {HX : GoWrapper X} {D : DefaultValue B}
  ovar avar bvar xvar (o : option B)
  (pnone : prog X) xpnone (psome : B -> prog X) xpsome (F : pred) C,
  (forall (b : B),
  EXTRACT (psome b)
  {{ avar ~> true * bvar ~> b * ovar |-> moved_value (wrap o) * F }}
    xpsome
  {{ fun ret => xvar ~> ret * avar ~>? bool * bvar ~>? B * ovar ~>? option B * C }} // env) ->
  EXTRACT pnone
  {{ avar ~> false * bvar ~> zeroval * ovar |-> moved_value (wrap o) * F }}
    xpnone
  {{ fun ret => xvar ~> ret * avar ~>? bool * bvar ~>? B * ovar ~>? option B * C }} // env ->
  EXTRACT (match o with
           | None => pnone
           | Some b => psome b
           end)
  {{ ovar ~> o * avar ~>? bool * bvar ~>? B * F }}
    Modify SplitPair (ovar, avar, bvar) ;
    If Var avar Then xpsome Else xpnone EndIf
  {{ fun ret => xvar ~> ret * avar ~>? bool * bvar ~>? B * ovar ~>? option B * C }} // env.
Proof.
  intros.
  eapply extract_equiv_prog with (pr1 := Bind (Ret tt) (fun _ => _)).
  rewrite bind_left_id. apply prog_equiv_equivalence.
  eapply CompileSeq.
  {
    eapply hoare_strengthen_pre;
    [ | eapply CompileSplit with (p := match o with
                                       | None => (false, zeroval)
                                       | Some b => (true, b)
                                       end)].
    destruct o; simpl. cancel_go.
    unfold wrap. simpl.
    erewrite <- default_zero' by apply default_zero. cancel_go.
  }
  destruct o; simpl in *.
  + unfold ProgOk; inv_exec_progok.
    - inv_exec.
      inv_exec; eval_expr.
      edestruct H; eauto.
      simpl. pred_solve.
      forward_solve.
    - inv_exec; inv_exec; eval_expr.
      edestruct H; eauto.
      simpl. pred_solve.
      forward_solve.
    - inv_exec.
      inv_exec; eval_expr.
      edestruct H; eauto.
      simpl. pred_solve.
      forward_solve.
      contradiction H3.
      repeat eexists. apply StepIfTrue. eval_expr.
  + erewrite <- default_zero' in * by apply default_zero.
    unfold ProgOk; inv_exec_progok.
    - inv_exec.
      inv_exec; eval_expr.
      edestruct H0; eauto.
      simpl. pred_solve.
      forward_solve.
    - inv_exec; inv_exec; eval_expr.
      edestruct H0; eauto.
      simpl. pred_solve.
      forward_solve.
    - inv_exec.
      inv_exec; eval_expr.
      edestruct H0; eauto.
      simpl. pred_solve.
      forward_solve.
      contradiction H3.
      repeat eexists. apply StepIfFalse. eval_expr.
Qed.