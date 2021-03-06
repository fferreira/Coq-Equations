(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2016 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)

From Equations Require Import Equations Fin DepElimDec.
Require Import Omega.

Section list_size.
  Context {A : Type} (f : A -> nat).
  Equations(nocomp) list_size (l : list A) : nat :=
  list_size nil := 0;
  list_size (cons x xs) := S (f x + list_size xs).

  Context {B : Type}.
  Equations(nocomp) list_map_size (l : list A)
           (g : forall (x : A), f x < list_size l -> B) : list B :=
  list_map_size nil _ := nil;
  list_map_size (cons x xs) g := cons (g x _) (list_map_size xs (fun x H => g x _)).
  Next Obligation.
    simp list_size. auto with arith.
  Defined.    
  Next Obligation.
    simp list_size. omega.
  Defined.    

  Lemma list_map_size_spec (g : A -> B) (l : list A) :
    list_map_size l (fun x _ => g x) = List.map g l.
  Proof.
    funelim (list_map_size l (λ (x : A) (_ : f x < list_size l), g x)); simpl; trivial.
    now rewrite H.
  Qed.
End list_size.

Require Import List.

Module RoseTree.

  Section roserec.
    Context {A : Set} {A_eqdec : EqDec.EqDec A}.
    
    Inductive t : Set :=
    | leaf (a : A) : t
    | node (l : list t) : t.
    Derive NoConfusion for t.
    
    Fixpoint size (r : t) :=
      match r with
      | leaf a => 0
      | node l => list_size size l
      end.

    Section elimtree.
      Context (P : t -> Type) (Pleaf : forall a, P (leaf a))
              (Pnil : P (node nil))
              (Pnode : forall x xs, P x -> P (node xs) -> P (node (cons x xs))).
              
      Equations(nocomp noind) elim (r : t) : P r :=
      elim r by rec r (MR lt size) :=
      elim (leaf a) := Pleaf a;
      elim (node nil) := Pnil;
      elim (node (cons x xs)) := Pnode x xs (elim x) (elim (node xs)).

      Next Obligation.
        red. simpl. omega.
      Defined.
      Next Obligation.
        red. simpl. omega.
      Defined.
    End elimtree.

    (* TODO where clauses *)
    Equations(nocomp) elements (r : t) : list A :=
    elements l by rec r (MR lt size) :=
    elements (leaf a) := [a];
    elements (node l) := concat (list_map_size size l (fun x H => elements x)).

    (* TODO where clauses *)
    Equations(nocomp noind noeqns) elements' (r : t) : list A :=
    elements' l by rec r (MR lt size) :=
    elements' (leaf a) := [a];
    elements' (node l) by rec l (MR lt (list_size size)) recl :=
      elements' nil rect H := nil;
      elements' (cons a x) rect H := rect a _ ++ recl x (fun y H => rect y _) _.

    Next Obligation.
      red; simpl. omega.
    Defined.
    Next Obligation.
      red; simpl. omega.
    Defined.
    Next Obligation.
      red; simpl. red; simpl. omega.
    Defined.

    Equations(nocomp) elements_def (r : t) : list A :=
    elements_def (leaf a) := [a];
    elements_def (node l) := concat (List.map elements l).

    Lemma elements_equation (r : t) : elements r = elements_def r.
    Proof.
      funelim (elements r); simp elements_def.
      now rewrite list_map_size_spec.
    Qed.
  End roserec.
  Arguments t : clear implicits.

  Section fns.
    Context {A B : Set} (f : A -> B) (g : B -> A -> B) (h : A -> B -> B).
    
    Equations(nocomp) map (r : t A) : t B :=
    map (leaf a) := leaf (f a);
    map (node l) := node (List.map map l).

    Equations(nocomp) fold (acc : B) (r : t A) : B :=
    fold acc (leaf a) := g acc a;
    fold acc (node l) := List.fold_left fold l acc.

    Equations(nocomp) fold_right (r : t A) (acc : B) : B :=
    fold_right (leaf a) acc := h a acc;
    fold_right (node l) acc := List.fold_right fold_right acc l.
  End fns.    

End RoseTree.
