Require Import Arith.
Require Import Pred PredCrash.
Require Import Word.
Require Import Prog ProgMonad.
Require Import Hoare.
Require Import SepAuto.
Require Import BasicProg.
Require Import Omega.
Require Import Log.
Require Import Array.
Require Import List ListUtils.
Require Import Bool.
Require Import Eqdep_dec.
Require Import Setoid.
Require Import Rec.
Require Import FunctionalExtensionality.
Require Import NArith.
Require Import WordAuto.
Require Import RecArrayUtils LogRecArray.
Require Import GenSepN.
Require Import Balloc.
Require Import ListPred.
Require Import FSLayout.
Require Import AsyncDisk.

Import ListNotations.

Set Implicit Arguments.


Module Type BlockPtrSig.

  Parameter irec     : Type.               (* inode record type *)
  Parameter iattr    : Type.               (* part of irec that BlockPtr does not touch *)
  Parameter NDirect  : addr.               (* number of direct blocks *)

  (* Number of direct blocks should be quite small to avoid word overflow 
     Using addrlen as its bound is arbitrary *)
  Parameter NDirect_bound : NDirect <= addrlen.

  Parameter IRLen    : irec -> addr.       (* get length *)
  Parameter IRIndPtr : irec -> addr.       (* get indirect block pointer *)
  Parameter IRBlocks : irec -> list waddr. (* get direct block numbers *)
  Parameter IRAttrs  : irec -> iattr.      (* get untouched attributes *)

  (* setters *)
  Parameter upd_len  : irec -> addr -> irec.
  Parameter upd_irec : forall (r : irec) (len : addr) (ibptr : addr) (dbns : list waddr), irec.

  (* getter/setter lemmas *)
  Parameter upd_len_get_len    : forall ir n, goodSize addrlen n -> IRLen (upd_len ir n) = n.
  Parameter upd_len_get_ind    : forall ir n, IRIndPtr (upd_len ir n) = IRIndPtr ir.
  Parameter upd_len_get_blk    : forall ir n, IRBlocks (upd_len ir n) = IRBlocks ir.
  Parameter upd_len_get_iattr  : forall ir n, IRAttrs (upd_len ir n) = IRAttrs ir.

  Parameter upd_irec_get_len   : forall ir len ibptr dbns,
     goodSize addrlen len -> IRLen (upd_irec ir len ibptr dbns) = len.
  Parameter upd_irec_get_ind   : forall ir len ibptr dbns,
     goodSize addrlen ibptr -> IRIndPtr (upd_irec ir len ibptr dbns) = ibptr.
  Parameter upd_irec_get_blk   : forall ir len ibptr dbns,
     IRBlocks (upd_irec ir len ibptr dbns) = dbns.
  Parameter upd_irec_get_iattr : forall ir len ibptr dbns,
      IRAttrs (upd_irec ir len ibptr dbns) = IRAttrs ir.

End BlockPtrSig.


(* block pointer abstraction for individule inode *)
Module BlockPtr (BPtr : BlockPtrSig).

  Import BPtr.


  (* RecArray for indirect blocks *)

  Definition indrectype := Rec.WordF addrlen.

  Module IndSig <: RASig.

    Definition xparams := addr.
    Definition RAStart := fun (x : xparams) => x.
    Definition RALen := fun (_ : xparams) => 1.
    Definition xparams_ok (_ : xparams) := True.

    Definition itemtype := indrectype.
    Definition items_per_val := valulen / (Rec.len itemtype).

    Theorem blocksz_ok : valulen = Rec.len (Rec.ArrayF itemtype items_per_val).
    Proof.
      unfold items_per_val.
      rewrite valulen_is; compute; auto.
    Qed.

  End IndSig.

  Module IndRec  := LogRecArray IndSig.
  Hint Extern 0 (okToUnify (IndRec.rep _ _) (IndRec.rep _ _)) => constructor : okToUnify.

  Notation "'NIndirect'" := IndSig.items_per_val.
  Notation "'NBlocks'"   := (NDirect + NIndirect)%nat.

  (* Various bounds *)
  Lemma NIndirect_is : NIndirect = 512.
  Proof.
    unfold IndSig.items_per_val.
    rewrite valulen_is; compute; auto.
  Qed.

  Lemma NBlocks_roundtrip : # (natToWord addrlen NBlocks) = NBlocks.
  Proof.
    unfold IndSig.items_per_val.
    erewrite wordToNat_natToWord_bound with (bound:=$ valulen).
    reflexivity.
    eapply le_trans.
    eapply plus_le_compat_r.
    apply NDirect_bound.
    apply Nat.sub_0_le.
    rewrite valulen_is.
    compute; reflexivity.
  Qed.

  Lemma NDirect_roundtrip : # (natToWord addrlen NDirect) = NDirect.
  Proof.
    intros.
    eapply wordToNat_natToWord_bound with (bound := natToWord addrlen NBlocks).
    rewrite NBlocks_roundtrip; omega.
  Qed.

  Lemma NIndirect_roundtrip : # (natToWord addrlen NIndirect) = NIndirect.
  Proof.
    intros.
    eapply wordToNat_natToWord_bound with (bound := natToWord addrlen NBlocks).
    rewrite NBlocks_roundtrip; omega.
  Qed.

  Lemma le_ndirect_goodSize : forall n,
    n <= NDirect -> goodSize addrlen n.
  Proof.
    intros; eapply goodSize_word_bound; eauto.
    rewrite NDirect_roundtrip; auto.
  Qed.

  Lemma le_nindirect_goodSize : forall n,
    n <= NIndirect -> goodSize addrlen n.
  Proof.
    intros; eapply goodSize_word_bound; eauto.
    rewrite NIndirect_roundtrip; auto.
  Qed.

  Lemma le_nblocks_goodSize : forall n,
    n <= NBlocks -> goodSize addrlen n.
  Proof.
    intros; eapply goodSize_word_bound; eauto.
    rewrite NBlocks_roundtrip; auto.
  Qed.

  Local Hint Resolve le_ndirect_goodSize le_nindirect_goodSize le_nblocks_goodSize.


  (************* program *)

  Fixpoint indget (indlvl : nat) lxp (bn : addr) off ms :=
    let divisor := NIndirect ^ indlvl in
    let^ (ms, v) <- IndRec.get lxp bn (off / divisor) ms;
    match indlvl with
    | 0 => Ret ^(ms, v)
    | S indlvl' => indget indlvl' lxp (# (Rec.to_word v)) (off mod divisor) ms
    end.

  Definition get lxp (ir : irec) off ms :=
    If (lt_dec off NDirect) {
      Ret ^(ms, selN (IRBlocks ir) off $0)
    } else {
      let^ (ms, v) <- indget 0 lxp (IRIndPtr ir) (off - NDirect) ms;
      Ret ^(ms, v)
    }.

  Definition read lxp (ir : irec) ms :=
    If (le_dec (IRLen ir) NDirect) {
      Ret ^(ms, firstn (IRLen ir) (IRBlocks ir))
    } else {
      let^ (ms, indbns) <- IndRec.read lxp (IRIndPtr ir) 1 ms;
      Ret ^(ms, (firstn (IRLen ir) ((IRBlocks ir) ++ indbns)))
    }.


  Definition free_ind_dec ol nl :
    { ol > NDirect /\ nl <= NDirect } + { ol <= NDirect \/ nl > NDirect }.
  Proof.
    destruct (gt_dec ol NDirect).
    destruct (le_dec nl NDirect).
    left; split; assumption.
    right; right; apply not_le; assumption.
    right; left; apply not_gt; assumption.
  Defined.


  Definition shrink lxp bxp (ir : irec) nr ms :=
    let nl := ((IRLen ir) - nr) in
    If (free_ind_dec (IRLen ir) nl) {
      ms <- BALLOC.free lxp bxp (IRIndPtr ir) ms;
      Ret ^(ms, upd_len ir nl)
    } else {
      Ret ^(ms, upd_len ir nl)
    }.


  Definition grow lxp bxp (ir : irec) bn ms :=
    let len := (IRLen ir) in
    If (lt_dec len NDirect) {
      (* change direct block address *)
      Ret ^(ms, Some (upd_irec ir (S len) (IRIndPtr ir) (updN (IRBlocks ir) len bn)))
    } else {
      (* allocate indirect block if necessary *)
      let^ (ms, ibn) <- If (addr_eq_dec len NDirect) {
        let^ (ms, r) <- BALLOC.alloc lxp bxp ms;
        match r with
        | None => Ret ^(ms, None)
        | Some ibn =>
            ms <- IndRec.init lxp ibn ms;
            Ret ^(ms, Some ibn)
        end
      } else {
        Ret ^(ms, Some (IRIndPtr ir))
      };
      match ibn with
      | Some ibn =>
        (* write indirect block *)
        ms <- IndRec.put lxp ibn (len - NDirect) bn ms;
        Ret ^(ms, Some (upd_irec ir (S len) ibn (IRBlocks ir)))
      | None => Ret ^(ms, None)
      end
    }.

  (************** rep invariant *)
  Fixpoint indrep_ind bxp (indlvl : nat) (ibn : addr) (l : list waddr):=
    ([[ length l = NIndirect ^ (S indlvl) ]] * [[ BALLOC.bn_valid bxp ibn ]] *
    match indlvl with
    | 0 => IndRec.rep ibn l
    | S indlvl' => exists iblocks l_part, 
      IndRec.rep ibn iblocks *
      [[ length iblocks = NIndirect ]] *
      [[ l = concat l_part ]] *
      listmatch (fun ibn' l' => indrep_ind bxp indlvl' (# ibn') l') iblocks l_part
    end)%pred.
  Hint Extern 0 (okToUnify (indrep_ind _ _ _ _) (indrep_ind _ _ _ _)) => constructor : okToUnify.

  Definition indrep bxp (l : list waddr) ibn indlist :=
    ( [[ length l <= NDirect ]] \/
      [[ length l > NDirect ]] * indrep_ind bxp 0 ibn indlist )%pred.

  Definition rep bxp (ir : irec) (l : list waddr) :=
    ( [[ length l = (IRLen ir) /\ length l <= NBlocks ]] *
      [[ length (IRBlocks ir) = NDirect ]] *
      exists indlist, indrep bxp l (IRIndPtr ir) indlist *
      [[ l = firstn (length l) ((IRBlocks ir) ++ indlist) ]] )%pred.

  Definition rep_direct (ir : irec) (l : list waddr) : @pred _ addr_eq_dec valuset :=
    ( [[ length l = (IRLen ir) /\ length l <= NBlocks /\ length l <= NDirect ]] *
      [[ length (IRBlocks ir) = NDirect ]] *
      [[ l = firstn (length l) (IRBlocks ir) ]] )%pred.

  Definition rep_indirect bxp (ir : irec) (l : list waddr) :=
    ( [[ length l = (IRLen ir) /\ length l <= NBlocks /\ length l > NDirect ]] *
      [[ length (IRBlocks ir) = NDirect ]] *
      exists indlist, indrep_ind bxp 0 (IRIndPtr ir) indlist *
      [[ length indlist = NIndirect ]] *
      [[ l = (IRBlocks ir) ++ firstn (length l - NDirect) indlist ]] )%pred.

  (* Necessary to make subst work when there's a recursive term like:
     l = firstn (length l) ... *)
  Set Regular Subst Tactic.

  Lemma rep_piff_direct : forall bxp ir l,
    length l <= NDirect ->
    rep bxp ir l <=p=> rep_direct ir l.
  Proof.
    unfold rep, indrep, rep_direct; intros; split; cancel; try omega.
    substl l at 1; rewrite firstn_app_l by omega; auto.
    rewrite app_nil_r; auto.
  Qed.


  Lemma rep_piff_indirect : forall bxp ir l,
    length l > NDirect ->
    rep bxp ir l <=p=> rep_indirect bxp ir l.
  Proof.
    unfold rep, indrep, rep_indirect; intros; split; cancel; try omega.
    rewrite <- firstn_app_r; setoid_rewrite H3.
    replace (NDirect + (length l - NDirect)) with (length l) by omega; auto.
    substl l at 1; rewrite <- firstn_app_r. setoid_rewrite H3.
    replace (NDirect + (length l - NDirect)) with (length l) by omega; auto.
    Unshelve. eauto.
  Qed.


  Lemma rep_selN_direct_ok : forall F bxp ir l m off,
    (F * rep bxp ir l)%pred m ->
    off < NDirect ->
    off < length l ->
    selN (IRBlocks ir) off $0 = selN l off $0.
  Proof.
    unfold rep, indrep; intros; destruct_lift H.
    substl.
    rewrite selN_firstn by auto.
    rewrite selN_app1 by omega; auto.
  Qed.

  Lemma off_mod_len_l : forall T off (l : list T), length l = NIndirect -> off mod NIndirect < length l.
  Proof.
    intros. rewrite H; apply Nat.mod_upper_bound; apply IndRec.Defs.items_per_val_not_0.
  Qed.

  Lemma mult_neq_0 : forall m n, m <> 0 -> n <> 0 -> m * n <> 0.
  Proof.
    intros. intuition.
    apply mult_is_O in H1.
    destruct H1; auto.
  Qed.

  Hint Resolve off_mod_len_l.
  Hint Resolve IndRec.Defs.items_per_val_not_0.
  Hint Resolve IndRec.Defs.items_per_val_gt_0'.
  Hint Resolve mult_neq_0.

  Lemma indrep_ind_lift : forall bxp indlvl bn l,
    indrep_ind bxp indlvl bn l <=p=>
    ([[ length l = NIndirect ^ S indlvl ]] * [[ BALLOC.bn_valid bxp bn ]] * indrep_ind bxp indlvl bn l)%pred.
  Proof.
    unfold indrep_ind.
    split; induction indlvl; cancel.
    auto.
    auto.
  Qed.

  Fact divmod_n_zeros : forall n, fst (Nat.divmod n 0 0 0) = n.
  Proof.
    intros.
    pose proof Nat.div_1_r n.
    unfold Nat.div in H.
    assumption.
  Qed.

  Hint Rewrite divmod_n_zeros using auto.

  Local Hint Resolve Nat.pow_nonzero.

  Ltac mult_nonzero := 
    repeat (match goal with 
    | [ |- mult _ _ <> 0 ] => apply mult_neq_0
    | [ |- mult _ _ > 0 ] => apply lt_mul_mono
    | [ |- 0 < Nat.pow _ _ ] => apply neq_0_lt, not_eq_sym
    end; auto).

  Fact listmatch_indrep_off : forall F T bxp indlvl (l1 : list T) l2 g off m,
    length l1 = NIndirect -> off < length (concat l2) ->
    (F * listmatch (fun a b => indrep_ind bxp indlvl (g a) b) l1 l2)%pred m
    -> off / (NIndirect * NIndirect ^ indlvl) < length l1.
  Proof.
    intros.
    apply listmatch_length_r in H1 as HH.
    eapply listmatch_lift_r in H1.
    apply concat_hom_length with (k := NIndirect ^ S indlvl) in H1.
    rewrite HH in *.
    apply Nat.div_lt_upper_bound.
    mult_nonzero.
    rewrite H1 in H0.
    rewrite H in *.
    simpl in *.
    rewrite mult_comm; auto.
    intros; rewrite indrep_ind_lift; split; cancel.
  Qed.

  Lemma listmatch_indrep_ind_length : forall F T bxp indlvl g (l1 : list T) l2 m,
    (F * listmatch (fun a b => indrep_ind bxp indlvl (g a) b) l1 l2)%pred m ->
    length l1 = NIndirect ->
    length (concat l2) = NIndirect ^ S (S indlvl).
  Proof.
    intros.
    apply listmatch_length_r in H as HH; rewrite HH in H0.
    eapply listmatch_lift_r in H.
    apply concat_hom_length in H.
    rewrite H0 in H.
    eassumption.
    intros.
    rewrite indrep_ind_lift.
    split; cancel.
  Qed.

  Theorem indget_ok : forall indlvl lxp bxp bn off ms,
    {< F Fm m0 m l,
    PRE:hm
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm *
           [[[ m ::: Fm * indrep_ind bxp indlvl bn l ]]] *
           [[ off < length l ]]
    POST:hm' RET:^(ms, r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm' *
           [[ r = selN l off $0 ]]
    CRASH:hm'  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms' hm'
    >} indget indlvl lxp bn off ms.
  Proof.
    induction indlvl.
    unfold indget; hoare; autorewrite with core; auto.
    unfold indget; hoare.
    - apply Nat.div_lt_upper_bound; mult_nonzero.
      rewrite H13.
      rewrite Nat.mul_shuffle0, mult_assoc_reverse; omega.
    - erewrite listmatch_isolate. cancel.
      eapply listmatch_indrep_off; eauto.
      apply listmatch_length_r in H0 as HH; rewrite <- HH in *; auto.
      eapply listmatch_indrep_off in H0; eauto.
    - erewrite listmatch_isolate in H0.
      rewrite indrep_ind_lift in H0.
      destruct_lift H0.
      rewrite H11.
      apply Nat.mod_upper_bound; mult_nonzero.
      eapply listmatch_indrep_off; eauto.
      apply listmatch_length_r in H0 as HH.
      eapply listmatch_indrep_off in H0; eauto.
    - apply selN_selN_homogenous.
      eapply listmatch_lift_r in H0; try eassumption.
      intros; rewrite indrep_ind_lift; split; cancel.
      apply listmatch_length_r in H0 as HH; rewrite <- HH in *.
      eapply listmatch_indrep_off in H0; eauto.
      apply Rounding.div_lt_mul_lt in H0; rewrite Nat.mul_comm; auto.
      mult_nonzero.
    Grab Existential Variables.
    exact ($ off).
  Qed.

  Opaque indget.
  Hint Extern 1 ({{_}} Bind (indget _ _ _ _ _) _) => apply indget_ok : prog.

  Theorem get_ok : forall lxp bxp ir off ms,
    {< F Fm m0 m l,
    PRE:hm
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm *
           [[[ m ::: Fm * rep bxp ir l ]]] *
           [[ off < length l ]]
    POST:hm' RET:^(ms, r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm' *
           [[ r = selN l off $0 ]]
    CRASH:hm'  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms' hm'
    >} get lxp ir off ms.
  Proof.
    unfold get.
    step.
    step.
    eapply rep_selN_direct_ok; eauto.

    prestep; norml.
    rewrite rep_piff_indirect in H0 by omega.
    unfold rep_indirect in H0; destruct_lift H0; cancel; try omega.
    eassumption.
    step; substl.
    substl NDirect; rewrite selN_app2.
    rewrite selN_firstn by omega; auto.
    omega.
  Qed.


  Theorem read_ok : forall lxp bxp ir ms,
    {< F Fm m0 m l,
    PRE:hm
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm *
           [[[ m ::: Fm * rep bxp ir l ]]]
    POST:hm' RET:^(ms, r)
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm' *
           [[ r = l ]]
    CRASH:hm'  exists ms',
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms' hm'
    >} read lxp ir ms.
  Proof.
    unfold read.
    step; denote rep as Hx.
    step.
    rewrite rep_piff_direct in Hx; unfold rep_direct in Hx; destruct_lift Hx.
    substl; substl (length l); auto.
    unfold rep in H; destruct_lift H; omega.

    prestep; norml.
    rewrite rep_piff_indirect in Hx.
    unfold rep_indirect in Hx; destruct_lift Hx; cancel.
    step; substl.
    rewrite Nat.add_0_r, firstn_app_le by omega.
    setoid_rewrite firstn_oob at 2; try omega.
    substl (length l); substl NDirect; auto.
    unfold rep in Hx; destruct_lift Hx; omega.
  Qed.



  Lemma indrec_ptsto_pimpl : forall ibn indrec,
    IndRec.rep ibn indrec =p=> exists v, ibn |-> (v, nil).
  Proof.
    unfold IndRec.rep; cancel.
    assert (length (synced_list (IndRec.Defs.ipack indrec)) = 1).
    unfold IndRec.items_valid in H2; intuition.
    rewrite synced_list_length; subst.
    rewrite IndRec.Defs.ipack_length.
    setoid_rewrite H0.
    rewrite Rounding.divup_mul; auto.
    apply IndRec.Defs.items_per_val_not_0.

    rewrite arrayN_isolate with (i := 0) by omega.
    unfold IndSig.RAStart; rewrite Nat.add_0_r.
    rewrite skipn_oob by omega; simpl.
    instantiate (2 := ($0, nil)).
    rewrite synced_list_selN; cancel.
  Qed.

  Hint Rewrite cuttail_length : core.
  Hint Rewrite upd_len_get_len upd_len_get_ind upd_len_get_blk upd_len_get_iattr : core.
  Hint Rewrite upd_irec_get_len upd_irec_get_ind upd_irec_get_blk upd_irec_get_iattr : core.
  Local Hint Resolve upd_len_get_iattr upd_irec_get_iattr.

  Theorem shrink_ok : forall lxp bxp ir nr ms,
    {< F Fm m0 m l freelist,
    PRE:hm
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm *
           [[[ m ::: (Fm * rep bxp ir l * BALLOC.rep bxp freelist) ]]]
    POST:hm' RET:^(ms, r)  exists m' freelist',
           LOG.rep lxp F (LOG.ActiveTxn m0 m') ms hm' *
           [[[ m' ::: (Fm * rep bxp r (cuttail nr l) * BALLOC.rep bxp freelist') ]]] *
           [[ r = upd_len ir ((IRLen ir) - nr) ]] *
           [[ incl freelist freelist' ]]
    CRASH:hm'  LOG.intact lxp F m0 hm'
    >} shrink lxp bxp ir nr ms.
  Proof.
    unfold shrink.
    prestep; norml.
    assert (length l = (IRLen ir)); denote rep as Hx.
    unfold rep in Hx; destruct_lift Hx; omega.

    (* needs to free indirect block *)
    prestep; norml.
    rewrite rep_piff_indirect in Hx by omega.
    unfold rep_indirect in Hx; destruct_lift Hx.
    denote IndRec.rep as Hx; rewrite indrec_ptsto_pimpl in Hx.
    destruct_lift Hx; cancel.

    step.
    rewrite rep_piff_direct by (rewrite cuttail_length; omega).
    unfold rep_direct; cancel; autorewrite with core; try omega.
    apply le_ndirect_goodSize; omega.

    substl l at 1; unfold cuttail.
    rewrite app_length, firstn_length_l by omega.
    rewrite firstn_app_l by omega.
    f_equal; omega.

    (* no free indirect block *)
    cancel.

    (* case 1: all in direct blocks *)
    repeat rewrite rep_piff_direct by (autorewrite with core; omega).
    unfold rep_direct; cancel; autorewrite with core; try omega.
    apply le_ndirect_goodSize; omega.

    substl l at 1; unfold cuttail.
    rewrite firstn_length_l by omega.
    rewrite firstn_firstn, Nat.min_l by omega; auto.

    (* case 1: all in indirect blocks *)
    repeat rewrite rep_piff_indirect by (autorewrite with core; omega).
    unfold rep_indirect; cancel; autorewrite with core; eauto; try omega.
    apply le_nblocks_goodSize; omega.

    substl l at 1; unfold cuttail.
    rewrite app_length, firstn_length_l by omega.
    replace (length (IRBlocks ir) + (length l - NDirect) - nr) with
            (length (IRBlocks ir) + (length l - nr - NDirect)) by omega.
    rewrite firstn_app_r; f_equal.
    rewrite firstn_firstn, Nat.min_l by omega; auto.
  Qed.


  Theorem grow_ok : forall lxp bxp ir bn ms,
    {< F Fm m0 m l freelist,
    PRE:hm
           LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm *
           [[ length l < NBlocks ]] *
           [[[ m ::: (Fm * rep bxp ir l * BALLOC.rep bxp freelist) ]]]
    POST:hm' RET:^(ms, r)
           [[ r = None ]] * LOG.rep lxp F (LOG.ActiveTxn m0 m) ms hm' \/
           exists m' freelist' ir',
           [[ r = Some ir' ]] * LOG.rep lxp F (LOG.ActiveTxn m0 m') ms hm' *
           [[[ m' ::: (Fm * rep bxp ir' (l ++ [bn]) * BALLOC.rep bxp freelist') ]]] *
           [[ IRAttrs ir' = IRAttrs ir /\ length (IRBlocks ir') = length (IRBlocks ir) ]] *
           [[ incl freelist' freelist ]]
    CRASH:hm'  LOG.intact lxp F m0 hm'
    >} grow lxp bxp ir bn ms.
  Proof.
    unfold grow.
    prestep; norml.
    assert (length l = (IRLen ir)); denote rep as Hx.
    unfold rep in Hx; destruct_lift Hx; omega.
    cancel.

    (* only update direct block *)
    prestep; norml.
    rewrite rep_piff_direct in Hx by omega.
    unfold rep_direct in Hx; cancel.
    or_r; cancel.
    rewrite rep_piff_direct by (autorewrite with lists; simpl; omega).
    unfold rep_direct; autorewrite with core lists; simpl.
    cancel; try omega.
    substl l at 1; substl (length l).
    apply firstn_app_updN_eq; omega.
    apply le_nblocks_goodSize; omega.
    autorewrite with core lists; auto.

    (* update indirect blocks *)
    step.
    step.

    (* case 1 : need allocate indirect block *)
    step; try (eapply BALLOC.bn_valid_facts; eauto).
    unfold IndSig.xparams_ok; auto.
    instantiate (1 := [(dummy_cur, dummy_old)]); simpl; auto.
    simpl; unfold IndSig.RAStart; cancel.

    step.
    rewrite repeat_length; omega.
    step.
    or_r; cancel.
    rewrite rep_piff_direct by omega.
    rewrite rep_piff_indirect by (rewrite app_length; simpl; omega).
    unfold rep_direct, rep_indirect; cancel;
      repeat (autorewrite with core lists; simpl; eauto; try omega).
    eapply BALLOC.bn_valid_goodSize; eauto.
    apply le_nblocks_goodSize; omega.
    eapply BALLOC.bn_valid_goodSize; eauto.

    substl l at 1; substl (length l); substl (IRLen ir).
    rewrite firstn_oob, minus_plus, Nat.sub_diag by omega.
    erewrite firstn_S_selN, selN_updN_eq by (autorewrite with lists; omega).
    simpl; auto.
    autorewrite with core lists; auto.

    apply incl_remove.

    (* case 2 : just update the indirect block *)
    prestep; norml.
    rewrite rep_piff_indirect in Hx by omega.
    unfold rep_indirect in Hx; destruct_lift Hx; cancel; try omega.
    2: cancel.
    omega.

    step.
    or_r; cancel.
    rewrite rep_piff_indirect by (rewrite app_length; simpl; omega).
    unfold rep_indirect; cancel;
      repeat (autorewrite with core lists; simpl; eauto; try omega).
    eapply BALLOC.bn_valid_goodSize; eauto.
    apply le_nblocks_goodSize; omega.
    eapply BALLOC.bn_valid_goodSize; eauto.
    substl l at 1; substl (length l).
    replace (IRLen ir + 1 - NDirect) with (IRLen ir - NDirect + 1) by omega.
    rewrite <- app_assoc; f_equal.
    rewrite firstn_app_updN_eq; auto.
    substl (length dummy); omega.
    autorewrite with core lists; auto.

    cancel.

    Unshelve. all:eauto.
  Qed.

  Hint Extern 1 ({{_}} Bind (get _ _ _ _) _) => apply get_ok : prog.
  Hint Extern 1 ({{_}} Bind (read _ _ _) _) => apply read_ok : prog.
  Hint Extern 1 ({{_}} Bind (shrink _ _ _ _ _) _) => apply shrink_ok : prog.
  Hint Extern 1 ({{_}} Bind (grow _ _ _ _ _) _) => apply grow_ok : prog.

  Hint Extern 0 (okToUnify (rep _ _ _) (rep _ _ _)) => constructor : okToUnify.


  Theorem xform_rep : forall xp ir l,
    crash_xform (rep xp ir l) <=p=> rep xp ir l.
  Proof.
    unfold rep, indrep; intros; split.
    xform_norm.
    cancel; eauto.
    rewrite IndRec.xform_rep; cancel.

    cancel.
    xform_normr.
    rewrite crash_xform_exists_comm; cancel.
    xform_normr.
    cancel; eauto.

    cancel.
    xform_normr.
    rewrite crash_xform_exists_comm; cancel.
    xform_normr.
    cancel; eauto.
    or_r; cancel.
    rewrite IndRec.xform_rep; auto.
  Qed.

End BlockPtr.

