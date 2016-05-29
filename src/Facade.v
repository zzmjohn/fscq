Require Import PeanoNat String List FMapAVL.
Require Import Word StringMap.

Import ListNotations.

(* TODO: Call something other than "Facade?" *)

Set Implicit Arguments.

(* Don't print (elt:=...) everywhere *)
Unset Printing Implicit Defensive.

Local Open Scope string_scope.


Inductive prog T :=
| Done (v: T)
| Double (n: nat) (rx: nat -> prog T).

Example times20 n T rx : prog T :=
  Double (5*n) (fun n2 => Double n2 rx).

Inductive step T : prog T -> prog T -> Prop :=
| StepDouble : forall n rx, step (Double n rx) (rx (n + n)).

Hint Constructors step.

Inductive outcome (T : Type) :=
| Finished (v: T).

Inductive exec T : prog T -> outcome T -> Prop :=
| XStep : forall p p' out,
  step p p' ->
  exec p' out ->
  exec p out
| XDone : forall v,
  exec (Done v) (Finished v).

Hint Constructors exec.


Definition bad_computes_to A p (x : A) := exec (p (@Done A)) (Finished x).

Example bad_times20 T n rx : prog T :=
  match rx 5 with
  | Done _ => Double (5*n) (fun n2 => Double n2 rx)
  | Double _ _ => rx 2
  end.

Lemma bad_twotimes20 : bad_computes_to (bad_times20 2) 40.
Proof.
  do 4 econstructor.
Qed.

Definition computes_to A (p : forall T, (A -> prog T) -> prog T) (x : A) :=
  forall T (rx : A -> prog T) (y : T),
    exec (rx x) (Finished y) <-> exec (p T rx) (Finished y).

Infix "↝" := computes_to (at level 70).

Lemma twotimes20 : times20 2 ↝ 40.
Proof.
  intros T rx y.
  split; intro.
  + econstructor.
    econstructor.
    econstructor.
    econstructor.
    trivial.
  + inversion H; subst; clear H.
    inversion H0; subst; clear H0.
    inversion H1; subst; clear H1.
    inversion H; subst; clear H.
    trivial.
Qed.

Definition bad_times20' n T rx := @bad_times20 T n rx.

Lemma bad_twotimes20_fails : ~ bad_times20' 2 ↝ 40.
Proof.
  unfold computes_to.
  intro.
  specialize (H nat (fun n => match n with
    | 5 => Double 2 (@Done nat)
    | n => Done n
    end) 40).
  destruct H as [H _].
  specialize (H ltac:(do 2 econstructor)).
  inversion H; subst; clear H.
  inversion H0; subst; clear H0.
Qed.

Definition label := string.
Definition var := string.

Definition W := nat. (* Assume bignums? *)

Inductive binop := Plus | Minus | Times.
Inductive test := Eq | Ne | Lt | Le.

Inductive Expr :=
| Var : var -> Expr
| Const : W -> Expr
| Binop : binop -> Expr -> Expr -> Expr
| TestE : test -> Expr -> Expr -> Expr.

Notation "A < B" := (TestE Lt A B) : facade_scope.
Notation "A <= B" := (TestE Le A B) : facade_scope.
Notation "A <> B" := (TestE Ne A B) : facade_scope.
Notation "A = B" := (TestE Eq A B) : facade_scope.
Delimit Scope facade_scope with facade.

Notation "! x" := (x = 0)%facade (at level 70, no associativity).
Notation "A * B" := (Binop Times A B) : facade_scope.
Notation "A + B" := (Binop Plus A B) : facade_scope.
Notation "A - B" := (Binop Minus A B) : facade_scope.

Inductive Stmt :=
| Skip : Stmt
| Seq : Stmt -> Stmt -> Stmt
| If : Expr -> Stmt -> Stmt -> Stmt
| While : Expr -> Stmt -> Stmt
(* | Call : var -> label -> list var -> Stmt (* TODO *) *)
| Assign : var -> Expr -> Stmt.

Arguments Assign v val%facade.

Inductive Value :=
| SCA : W -> Value.
(* TODO ADT *)

Definition is_mutable v :=
  match v with
  | SCA _ => false
  end.


Definition State := StringMap.t Value.

Import StringMap.

Definition eval_binop (op : binop + test) a b :=
  match op with
    | inl Plus => a + b
    | inl Minus => a - b
    | inl Times => a * b
    | inr Eq => if Nat.eq_dec a b then 1 else 0
    | inr Ne => if Nat.eq_dec a b then 0 else 1
    | inr Lt => if Compare_dec.lt_dec a b then 1 else 0
    | inr Le => if Compare_dec.le_dec a b then 1 else 0
  end.

Definition eval_binop_m (op : binop + test) (oa ob : option Value) : option Value :=
  match oa, ob with
    | Some (SCA a), Some (SCA b) => Some (SCA (eval_binop op a b))
    | _, _ => None
  end.

Fixpoint eval (st : State) (e : Expr) : option Value :=
  match e with
    | Var x => find x st
    | Const w => Some (SCA w)
    | Binop op a b => eval_binop_m (inl op) (eval st a) (eval st b)
    | TestE op a b => eval_binop_m (inr op) (eval st a) (eval st b)
  end.

Definition eval_bool st e : option bool :=
  match eval st e with
    | Some (SCA w) => Some (if Nat.eq_dec w 0 then false else true)
    | _ => None
  end.

Definition is_true st e := eval_bool st e = Some true.
Definition is_false st e := eval_bool st e = Some false.

Definition mapsto_mutable x st :=
  match find x st with
  | Some v => is_mutable v
  | None => true
  end.

(* Definition Env := StringMap.t _. *)

Inductive RunsTo (* TODO env *) : Stmt -> State -> State -> Prop :=
| RunsToSkip : forall st,
    RunsTo Skip st st
| RunsToSeq : forall a b st st' st'',
    RunsTo a st st' ->
    RunsTo b st' st'' ->
    RunsTo (Seq a b) st st''
| RunsToIfTrue : forall cond t f st st',
    is_true st cond ->
    RunsTo t st st' ->
    RunsTo (If cond t f) st st'
| RunsToIfFalse : forall cond t f st st',
    is_false st cond ->
     RunsTo f st st' ->
    RunsTo (If cond t f) st st'
| RunsToWhileTrue : forall cond body st st' st'',
    let loop := While cond body in
    is_true st cond ->
    RunsTo body st st' ->
    RunsTo loop st' st'' ->
    RunsTo loop st st''
| RunsToWhileFalse : forall cond body st st',
    let loop := While cond body in
    is_false st cond ->
    RunsTo loop st st'
| RunsToAssign : forall x e st st' v,
    (* rhs can't be a mutable object, to prevent aliasing *)
    eval st e = Some v ->
    is_mutable v = false ->
    st' = add x v st ->
    RunsTo (Assign x e) st st'.

Arguments RunsTo prog%facade st st'.

Notation "A ; B" := (Seq A B) (at level 201, B at level 201, left associativity, format "'[v' A ';' '/' B ']'") : facade_scope.
Notation "x <- y" := (Assign x y) (at level 90) : facade_scope.
Notation "'__'" := (Skip) : facade_scope.
Notation "'While' A B" := (While A B) (at level 200, A at level 0, B at level 1000, format "'[v    ' 'While'  A '/' B ']'") : facade_scope.
Notation "'If' a 'Then' b 'Else' c 'EndIf'" := (If a b c) (at level 200, a at level 1000, b at level 1000, c at level 1000) : facade_scope.


(* TODO What here is actually necessary? *)

Class FacadeWrapper (WrappingType WrappedType: Type) :=
  { wrap:        WrappedType -> WrappingType;
    wrap_inj: forall v v', wrap v = wrap v' -> v = v' }.

Inductive NameTag T :=
| NTSome (key: string) (H: FacadeWrapper Value T) : NameTag T.

Arguments NTSome {T} key {H}.

Inductive ScopeItem :=
| SItem A (key : NameTag A) (val : forall T, (A -> prog T) -> prog T).

Notation "` k ->> v" := (SItem (NTSome k) v) (at level 50).

(* Not really a telescope; should maybe just be called Scope *)
(* TODO: use fmap *)
Definition Telescope := list ScopeItem.

Fixpoint SameValues st (tenv : Telescope) :=
  match tenv with
  | [] => True
  | SItem key val :: tail =>
    match key with
    | NTSome k =>
      match StringMap.find k st with
      | Some v => exists v', val ↝ v' /\ v = wrap v'
      | None => False
      end /\ SameValues (StringMap.remove k st) tail
    end
  end.

Notation "ENV ≲ TENV" := (SameValues ENV TENV) (at level 50).

Definition ProgOk (* env *) prog (initial_tstate final_tstate : Telescope) :=
  forall initial_state : State,
    initial_state ≲ initial_tstate ->
    (* Safe ... /\ *)
    forall final_state : State,
      RunsTo (* env *) prog initial_state final_state ->
      (final_state ≲ final_tstate).

Arguments ProgOk prog%facade_scope initial_tstate final_tstate.

Notation "{{ A }} P {{ B }}" :=
  (ProgOk (* EV *) P A B)
    (at level 60, format "'[v' '{{'  A  '}}' '/'    P '/' '{{'  B  '}}' ']'").

Ltac FacadeWrapper_t :=
  abstract (repeat match goal with
                   | _ => progress intros
                   | [ H : _ = _ |- _ ] => inversion H; solve [eauto]
                   | _ => solve [eauto]
                   end).

Instance FacadeWrapper_SCA : FacadeWrapper Value W.
Proof.
  refine {| wrap := SCA;
            wrap_inj := _ |}; FacadeWrapper_t.
Defined.

Instance FacadeWrapper_Self {A: Type} : FacadeWrapper A A.
Proof.
  refine {| wrap := id;
            wrap_inj := _ |}; FacadeWrapper_t.
Defined.

Instance FacadeWrapper_Bool : FacadeWrapper Value bool.
Proof.
  refine {| wrap := fun v => if (Bool.bool_dec v true) then (SCA 1) else (SCA 0);
            wrap_inj := _ |}.
  intros; destruct (Bool.bool_dec v true);
          destruct (Bool.bool_dec v' true);
          destruct v;
          destruct v';
          congruence.
Defined.

Notation "'ParametricExtraction' '#vars' x .. y '#program' post '#arguments' pre" :=
  (sigT (fun prog => (forall x, .. (forall y, {{ pre }} prog {{ [ `"out" ->> post ] }}) ..)))
    (at level 200,
     x binder,
     y binder,
     format "'ParametricExtraction' '//'    '#vars'       x .. y '//'    '#program'     post '//'    '#arguments'  pre '//'     ").

Definition ret A (x : A) : forall T, (A -> prog T) -> prog T := fun T rx => rx x.

Definition extract_code := projT1.

Lemma ret_computes_to : forall A (x x' : A), ret x ↝ x' -> x = x'.
Proof.
  unfold ret, computes_to.
  intros.
  specialize (H A (@Done A) x).
  destruct H as [_ H].
  specialize (H ltac:(do 2 econstructor)).
  inversion H; subst; clear H.
  inversion H0; subst; clear H0.
  trivial.
Qed.

Lemma ret_computes_to_refl : forall A (x : A), ret x ↝ x.
Proof.
  split; eauto.
Qed.

Hint Resolve ret_computes_to_refl.

(* TODO: use Pred.v's *)
Ltac deex :=
  match goal with
  | [ H : exists (varname : _), _ |- _ ] =>
    let newvar := fresh varname in
    destruct H as [newvar ?]; intuition subst
  end.

Example micro_double :
  ParametricExtraction
    #vars        x
    #program     (fun T => @Double T x)
    #arguments [`"x" ->> ret x ].
Proof.
  eexists.
  intros.
  instantiate (1 := ("out" <- Var "x" + Var "x")%facade).
  (* TODO! *)
  intro.
  intros.
  simpl in H.
  inversion H0.
  simpl.
  subst.
  rewrite StringMapFacts.add_eq_o; intuition.
  simpl in H3.
  destruct (find "x" initial_state); intuition.
  destruct v, v0.
  simpl in H3.
  deex.
  inversion H3; inversion H5; subst.
  apply ret_computes_to in H1; subst.
  eexists.
  split; [ | trivial ].
  split; eauto.
  intros.
  inversion H; subst; clear H.
  inversion H1; subst; clear H1.
  trivial.
Defined.


Example micro_if :
  ParametricExtraction
    #vars      flag (x y : nat)
    #program   ret (if (Bool.bool_dec flag true) then x else y)
    #arguments [`"flag" ->> ret flag ; `"x" ->> ret x ; `"y" ->> ret y].
Proof.
  eexists.
  intros.
  instantiate (1 := (If (Var "flag") Then (Assign "out" (Var "x")) Else (Assign "out" (Var "y")) EndIf)%facade).
  (* TODO! *)
  intro.
  intros.
  simpl in H.
  inversion H0.
  - inversion H7. simpl; subst; intuition.
    repeat rewrite StringMapFacts.add_eq_o in * by congruence.
    repeat rewrite StringMapFacts.remove_neq_o in * by congruence.
    unfold is_true, is_false, eval_bool, eval in *.
    destruct (find "flag" initial_state); intuition; subst.
    destruct (find "x" initial_state); intuition; subst.
    destruct (find "y" initial_state); intuition; subst.
    repeat deex.
    apply ret_computes_to in H3; apply ret_computes_to in H2; apply ret_computes_to in H1; subst.
    inversion H10; subst.
    eexists; intuition eauto.
    destruct (Bool.bool_dec v'1 true); try solve [ destruct (Nat.eq_dec 0 0); congruence ].
  - inversion H7. simpl; subst; intuition.
    repeat rewrite StringMapFacts.add_eq_o in * by congruence.
    repeat rewrite StringMapFacts.remove_neq_o in * by congruence.
    unfold is_true, is_false, eval_bool, eval in *.
    destruct (find "flag" initial_state); intuition; subst.
    destruct (find "x" initial_state); intuition; subst.
    destruct (find "y" initial_state); intuition; subst.
    repeat deex.
    apply ret_computes_to in H3; apply ret_computes_to in H2; apply ret_computes_to in H1; subst.
    inversion H10; subst.
    eexists; intuition eauto.
    destruct (Bool.bool_dec v'1 true); try solve [ destruct (Nat.eq_dec 1 0); congruence ].
Defined.

Definition micro_if_code := Eval lazy in (extract_code micro_if).
Print micro_if_code.