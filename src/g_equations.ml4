(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2016 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)


(*i camlp4deps: "grammar/grammar.cma" i*)

DECLARE PLUGIN "equations_plugin"

open Equations_common
open Extraargs
open Eauto
open Locusops
open Term
open Names
open Tactics
open Pp
open Nameops
open Refiner
open Errors
open Constrexpr
 
TACTIC EXTEND decompose_app
[ "decompose_app" ident(h) ident(h') constr(c) ] -> [ 
  Proofview.Goal.enter (fun gl ->
    let f, args = decompose_app c in
    let fty = Tacmach.New.pf_hnf_type_of gl f in
    let flam = mkLambda (Name (id_of_string "f"), fty, mkApp (mkRel 1, Array.of_list args)) in
      (Proofview.tclTHEN (letin_tac None (Name h) f None allHyps)
  	 (letin_tac None (Name h') flam None allHyps)))
  ]
END


(* TACTIC EXTEND abstract_match *)
(* [ "abstract_match" ident(hyp) constr(c) ] -> [ *)
(*   match kind_of_term c with *)
(*   | Case (_, _, c, _) -> letin_tac None (Name hyp) c None allHypsAndConcl *)
(*   | _ -> tclFAIL 0 (str"Not a case expression") *)
(* ] *)
(* END *)

(* TACTIC EXTEND autounfold_first *)
(* | [ "autounfold_first" hintbases(db) "in" hyp(id) ] -> *)
(*     [ autounfold_first (match db with None -> ["core"] | Some x -> x) (Some (id, InHyp)) ] *)
(* | [ "autounfold_first" hintbases(db) ] -> *)
(*     [ autounfold_first (match db with None -> ["core"] | Some x -> x) None ] *)
(* END *)

(* Sigma *)

open Proofview.Notations

TACTIC EXTEND get_signature_pack
[ "get_signature_pack" hyp(id) ident(id') ] -> [ 
  Proofview.Goal.enter (fun gl ->
    let gl = Proofview.Goal.assume gl in
    let env = Proofview.Goal.env gl in
    let sigma = Proofview.Goal.sigma gl in
    let sigma', sigsig, sigpack =
      Sigma.get_signature env sigma (Tacmach.New.pf_get_hyp_typ id gl) in
    Proofview.Unsafe.tclEVARS sigma' <*>
    letin_tac None (Name id') (mkApp (sigpack, [| mkVar id |])) None nowhere) ]
END
      
TACTIC EXTEND pattern_sigma
(* [ "pattern" "sigma" "left" hyp(id) ] -> [ *)
(*   Proofview.Goal.enter (fun gl -> *)
(*     let gl = Proofview.Goal.assume gl in *)
(*     let env = Proofview.Goal.env gl in *)
(*     let sigma = Proofview.Goal.sigma gl in *)
(*     let decl = Tacmach.New.pf_get_hyp id gl in *)
(*     let term = Option.get (Util.pi2 decl) in *)
(*     Sigma.pattern_sigma ~assoc_right:false term id env sigma) ] *)
| [ "pattern" "sigma" hyp(id) ] -> [
  Proofview.Goal.enter (fun gl ->
    let gl = Proofview.Goal.assume gl in
    let env = Proofview.Goal.env gl in
    let sigma = Proofview.Goal.sigma gl in
    let decl = Tacmach.New.pf_get_hyp id gl in
    let term = Option.get (Util.pi2 decl) in
    Sigma.pattern_sigma ~assoc_right:true term id env sigma) ]
END

open Tacmach

let curry_hyp env sigma hyp t =
  let curry t =
    match kind_of_term t with
    | Prod (na, dom, concl) ->
       let ctx, arg = Sigma.curry na dom in
       let term = mkApp (mkVar hyp, [| arg |]) in
       let ty = Reductionops.nf_betaiota sigma (Vars.subst1 arg concl) in
       Some (it_mkLambda_or_LetIn term ctx, it_mkProd_or_LetIn ty ctx)
    | _ -> None
  in curry t

open Closure.RedFlags

let red_curry () =
  let redpr pr = 
    fCONST (Projection.constant (Lazy.force pr)) in
  let reds = mkflags [redpr coq_pr1; redpr coq_pr2; fBETA; fIOTA] in
  Reductionops.clos_norm_flags reds

let curry_concl env sigma na dom codom =
  let ctx, arg = Sigma.curry na dom in
  let newconcl =
    let body = it_mkLambda_or_LetIn (Vars.subst1 arg codom) ctx in
    let inst = Termops.extended_rel_vect 0 ctx in
    red_curry () env sigma (it_mkProd_or_LetIn (mkApp (body, inst)) ctx) in
  let proj last (na, b, ty) (terms, acc) =
    if last then (acc :: terms, acc)
    else
      let term = mkProj (Lazy.force coq_pr1, acc) in
      let acc = mkProj (Lazy.force coq_pr2, acc) in
      (term :: terms, acc)
  in
  let terms, acc =
    match ctx with
    | hd :: (_ :: _ as tl) ->
       proj true hd (List.fold_right (proj false) tl ([], mkRel 1))
    | hd :: tl -> ([mkRel 1], mkRel 1)
    | [] -> ([mkRel 1], mkRel 1)
  in
  let sigma, ev =
    Evarutil.new_evar env sigma newconcl
  in
  let term = mkLambda (na, dom, mkApp (ev, CArray.rev_of_list terms)) in
  sigma, term

TACTIC EXTEND curry
[ "curry" hyp(id) ] -> [ 
  Proofview.V82.tactic 
    (fun gl ->
      match curry_hyp (pf_env gl) (project gl) id (pf_get_hyp_typ gl id) with
      | Some (prf, typ) -> 
	 (tclTHENFIRST (Proofview.V82.of_tactic (assert_before_replacing id typ))
		       (Tacmach.refine_no_check prf)) gl
      | None -> tclFAIL 0 (str"No currying to do in " ++ pr_id id) gl) ]
| ["curry"] -> [ 
    Proofview.Goal.nf_enter (fun gl ->
      let env = Proofview.Goal.env gl in
      let concl = Proofview.Goal.concl gl in
      match kind_of_term concl with
      | Prod (na, dom, codom) ->
         Proofview.Refine.refine
           (fun sigma ->
             let sigma, prf = curry_concl env sigma na dom codom in
             sigma, prf)
      | _ -> Tacticals.New.tclFAIL 0 (str"Goal cannot be curried"))
  ]
END

TACTIC EXTEND curry_hyps
[ "uncurry_hyps" ident(id) ] -> [ Sigma.uncurry_hyps id ]
END

TACTIC EXTEND uncurry_call
[ "uncurry_call" constr(c) ident(id) ] -> [
    Proofview.Goal.enter (fun gl ->
        let env = Proofview.Goal.env gl in
        let sigma = Proofview.Goal.sigma gl in
        let sigma, term, ty = Sigma.uncurry_call env sigma c in
        let sigma, _ = Typing.type_of env sigma term in
        Proofview.Unsafe.tclEVARS sigma <*>
          Tactics.letin_tac None (Name id) term (Some ty) nowhere)
      ]
END


(* TACTIC EXTEND pattern_tele *)
(* [ "pattern_tele" constr(c) ident(hyp) ] -> [ fun gl -> *)
(*   let settac = letin_tac None (Name hyp) c None onConcl in *)
(*     tclTHENLIST [settac; pattern_sigma c hyp] gl ] *)
(* END *)

(* Depelim *)

TACTIC EXTEND dependent_pattern
| ["dependent" "pattern" constr(c) ] -> [ 
  Proofview.V82.tactic (Depelim.dependent_pattern c) ]
END

TACTIC EXTEND dependent_pattern_from
| ["dependent" "pattern" "from" constr(c) ] ->
    [ Proofview.V82.tactic (Depelim.dependent_pattern ~pattern_term:false c) ]
END

TACTIC EXTEND pattern_call
[ "pattern_call" constr(c) ] -> [ of82 (Depelim.pattern_call c) ]
END

(* Noconf *)


VERNAC COMMAND EXTEND Equations_Logic CLASSIFIED AS QUERY
| [ "Equations" "Logic" sort(s) global(eq) global(eqr) global(z) global(o) global(ov) ] -> [
  let gr x = Lazy.from_val (Nametab.global x) in
  let open Misctypes in
  let s = match s with GProp -> InProp | GSet -> InSet | GType _ -> InType in
  Equations_common.(set_logic { logic_eqty = gr eq;
				logic_eqrefl = gr eqr;
				logic_sort = s;
				logic_zero = gr z;
				logic_one = gr o;
				logic_one_val = gr ov})
  ]
END

(* TACTIC EXTEND dependent_generalize *)
(* | ["dependent" "generalize" hyp(id) "as" ident(id') ] ->  *)
(*     [ fun gl -> generalize_sigma (pf_env gl) (project gl) (mkVar id) id' gl ] *)
(* END *)
(* TACTIC EXTEND dep_generalize_force *)
(* | ["dependent" "generalize" "force" hyp(id) ] ->  *)
(*     [ abstract_generalize ~generalize_vars:false ~force_dep:true id ] *)
(* END *)
(* TACTIC EXTEND dependent_generalize_eqs_vars *)
(* | ["dependent" "generalize" "vars" hyp(id) ] ->  *)
(*     [ abstract_generalize ~generalize_vars:true id ] *)
(* END *)
(* TACTIC EXTEND dependent_generalize_eqs_vars_force *)
(* | ["dependent" "generalize" "force" "vars" hyp(id) ] ->  *)
(*     [ abstract_generalize ~force_dep:true ~generalize_vars:true id ] *)
(* END *)

TACTIC EXTEND needs_generalization
| [ "needs_generalization" hyp(id) ] -> 
    [ Proofview.V82.tactic (fun gl -> 
      if Depelim.needs_generalization gl id 
      then tclIDTAC gl
      else tclFAIL 0 (str"No generalization needed") gl) ]
END

(* Equations *)

open Extraargs
TACTIC EXTEND solve_equations
  [ "solve_equations" tactic(destruct) tactic(tac) ] -> 
  [ of82 (Equations.solve_equations_goal (to82 (Tacinterp.eval_tactic destruct)) (to82 (Tacinterp.eval_tactic tac))) ]
END

TACTIC EXTEND simp
| [ "simp" ne_preident_list(l) clause(c) ] -> 
    [ of82 (Equations.simp_eqns_in c l) ]
| [ "simpc" constr_list(l) clause(c) ] -> 
    [ of82 (Equations.simp_eqns_in c (dbs_of_constrs l)) ]
END


(* let wit_r_equation_user_option : equation_user_option Genarg.uniform_genarg_type = *)
(*   Genarg.create_arg None "r_equation_user_option" *)

open Equations
open Syntax

ARGUMENT EXTEND equation_user_option
TYPED AS equation_user_option
PRINTED BY pr_r_equation_user_option
| [ "noind" ] -> [ OInd false ]
| [ "ind" ] -> [ OInd true ]
| [ "struct" ident(i) ] -> [ ORec (Some (loc, i)) ]
| [ "nostruct" ] -> [ ORec None ]
| [ "comp" ] -> [ OComp true ]
| [ "nocomp" ] -> [ OComp false ]
| [ "eqns" ] -> [ OEquations true ]
| [ "noeqns" ] -> [ OEquations false ]
END

ARGUMENT EXTEND equation_options
TYPED AS equation_options
PRINTED BY pr_equation_options
| [ "(" ne_equation_user_option_list(l) ")" ] -> [ l ]
| [ ] -> [ [] ]
END

let pr_lident _ _ _ (loc, id) = pr_id id

ARGUMENT EXTEND lident
TYPED AS lident
PRINTED BY pr_lident
| [ ident(i) ] -> [ (loc, i) ]
END


module Gram = Pcoq.Gram
module Vernac = Pcoq.Vernac_
module Tactic = Pcoq.Tactic

type binders_let2_argtype =
    (Constrexpr.local_binder list *
     (Names.identifier Loc.located option * Constrexpr.recursion_order_expr))
    Genarg.uniform_genarg_type
type deppat_equations_argtype = Syntax.pre_equation list Genarg.uniform_genarg_type

let wit_binders_let2 : binders_let2_argtype =
  Genarg.create_arg None "binders_let2"

let pr_raw_binders_let2 _ _ _ l = mt ()
let pr_glob_binders_let2 _ _ _ l = mt ()
let pr_binders_let2 _ _ _ l = mt ()

let binders_let2 : (local_binder list * (identifier Loc.located option * recursion_order_expr)) Gram.entry =
  Pcoq.create_generic_entry "binders_let2" (Genarg.rawwit wit_binders_let2)

let _ = Pptactic.declare_extra_genarg_pprule wit_binders_let2
  pr_raw_binders_let2 pr_glob_binders_let2 pr_binders_let2


let wit_deppat_equations : deppat_equations_argtype =
  Genarg.create_arg None "deppat_equations"

let pr_raw_deppat_equations _ _ _ l = mt ()
let pr_glob_deppat_equations _ _ _ l = mt ()
let pr_deppat_equations _ _ _ l = mt ()

let deppat_equations : Syntax.pre_equation list Gram.entry =
  Pcoq.create_generic_entry "deppat_equations" (Genarg.rawwit wit_deppat_equations)

let _ = Pptactic.declare_extra_genarg_pprule wit_deppat_equations
  pr_raw_deppat_equations pr_glob_deppat_equations pr_deppat_equations

open Glob_term
open Util
open Pcoq
open Prim
open Constr
open G_vernac
open Compat
open Tok

open Syntax

GEXTEND Gram
  GLOBAL: pattern deppat_equations binders_let2 lident;
 
  deppat_equations:
    [ [ l = LIST1 equation SEP ";" -> l ] ]
  ;

  binders_let2:
    [ [ l = binders -> l, (None, CStructRec)  ] ]
  ;
  
  equation:
    [ [ id = identref; 	pats = LIST1 ipatt; r = rhs -> (Some id, SignPats pats, r)
      | "|"; pats = LIST1 lpatt SEP "|"; r = rhs -> (None, RefinePats pats, r) 
    ] ]
  ;

  ipatt:
    [ [ "{"; id = identref; ":="; p = patt; "}" -> (Some id, p)
      | p = patt -> (None, p)
      ] ]
  ;
    
  patt:
    [ [ id = smart_global -> !@loc, PEApp ((!@loc,id), [])
      | "_" -> !@loc, PEWildcard
      | "("; p = lpatt; ")" -> p
      | "?("; c = Constr.lconstr; ")" -> !@loc, PEInac c
      | p = pattern LEVEL "0" -> !@loc, PEPat p
    ] ]
  ;

  lpatt:
    [ [ id = smart_global; pats = LIST0 patt -> !@loc, PEApp ((!@loc,id), pats)
      | p = patt -> p
    ] ]
  ;

  refine:
    [ [ cs = LIST1 Constr.lconstr SEP "," ->
          let rec build_refine acc = function
            | [] -> assert false
            | [c] -> fun e -> acc (Refine (c, e))
            | c :: cs ->
                let acc = fun e ->
                  acc (Refine (c, [(None, RefinePats [!@loc, PEWildcard], e)])) in
                build_refine acc cs
          in build_refine (fun e -> e) cs
    ] ]
  ;

  rhs:
    [ [ ":=!"; id = identref -> Empty id
      |":="; c = Constr.lconstr -> Program c
      |"=>"; c = Constr.lconstr -> Program c
      | ["with"|"<="]; ref = refine; [":="|"=>"]; e = equations -> ref e
      | "<-"; "(" ; t = Tactic.tactic; ")"; e = equations -> By (Inl t, e)
      | "by"; IDENT "rec"; c = constr; rel = OPT constr; id = OPT identref;
        [":="|"=>"]; e = deppat_equations -> Rec (c, rel, id, e)
    ] ]
  ;

  equations:
    [ [ "{"; l = deppat_equations; "}" -> l 
      | l = deppat_equations -> l
    ] ]
  ;

  END

VERNAC COMMAND EXTEND Define_equations CLASSIFIED AS SIDEFF
| [ "Equations" equation_options(opt) lident(i) binders_let2(l) 
      ":" lconstr(t) ":=" deppat_equations(eqs)
      (* decl_notation(nt) *) ] ->
    [ Equations.equations opt i l t [] eqs ]
      END

(* TACTIC EXTEND block_goal *)
(* [ "block_goal" ] -> [ of82 ( *)
(*   (fun gl -> *)
(*     let block = Lazy.force coq_block in *)
(*     let concl = pf_concl gl in *)
(*     let ty = pf_type_of gl concl in *)
(*     let evd = project gl in *)
(*     let newconcl = mkApp (block, [|ty; concl|]) in *)
(*     let evd, _ty = Typing.e_type_of (pf_env gl) evd newconcl in *)
(*       (\* msg_info (str "After e_type_of: " ++ pr_evar_map None evd); *\) *)
(*       tclTHEN (tclEVARS evd) *)
(* 	(convert_concl newconcl DEFAULTcast) gl)) ] *)
(* END *)
  
(* TACTIC EXTEND pattern_call *)
(* [ "pattern_call" constr(c) ] -> [ fun gl -> *)
(*   match kind_of_term c with *)
(*   | App (f, [| arg |]) -> *)
(*       let concl = pf_concl gl in *)
(*       let replcall = replace_term c (mkRel 1) concl in *)
(*       let replarg = replace_term arg (mkRel 2) replcall in *)
(*       let argty = pf_type_of gl arg and cty = pf_type_of gl c in *)
(*       let rels = [(Name (id_of_string "call"), None, replace_term arg (mkRel 1) cty); *)
(* 		  (Name (id_of_string "arg"), None, argty)] in *)
(*       let newconcl = mkApp (it_mkLambda_or_LetIn replarg rels, [| arg ; c |]) in *)
(* 	convert_concl newconcl DEFAULTcast gl  *)
(*   | _ -> tclFAIL 0 (str "Not a recognizable call") gl ] *)
(* END *)

(* Subterm *)


TACTIC EXTEND is_secvar
| [ "is_secvar" constr(x) ] ->
  [ match kind_of_term x with
    | Var id when Termops.is_section_variable id -> Proofview.tclUNIT ()
    | _ -> Tacticals.New.tclFAIL 0 (str "Not a section variable or hypothesis") ]
END

open Proofview.Goal

(** [refine_ho c]

  Matches a lemma [c] of type [∀ ctx, ty] with a conclusion of the form
  [∀ ctx, ?P args] using second-order matching on the problem
  [ctx |- ?P args = ty] and then refines the goal with [c]. *)

let refine_ho c =
  nf_enter (fun gl ->
    let env = env gl in
    let sigma = sigma gl in  
    let concl = concl gl in
    let ty = Tacmach.New.pf_apply Retyping.get_type_of gl c in
    let ts = Names.full_transparent_state in
    let evd = ref sigma in
    let rec aux env concl ty =
      match kind_of_term concl, kind_of_term ty with
      | Prod (na, b, t), Prod (na', b', t') ->
         let ok = Evarconv.e_conv ~ts env evd b b' in
         if not ok then
           error "Products do not match"
         else aux (Environ.push_rel (na,None,b) env) t t'
      (* | _, LetIn (na, b, _, t') -> *)
      (*    aux env t (subst1 b t') *)
      | _, App (ev, args) when isEvar ev ->
         let (evk, subst as ev) = destEvar ev in
         let sigma = !evd in
         let sigma,ev =
           Evarutil.evar_absorb_arguments env sigma ev (Array.to_list args) in
         let argoccs = Array.map_to_list (fun _ -> None) (snd ev) in
         let sigma, b = Evarconv.second_order_matching ts env sigma ev argoccs concl in
         if not b then
           error "Second-order matching failed"
         else Proofview.Unsafe.tclEVARS sigma <*>
                Proofview.Refine.refine ~unsafe:true (fun sigma -> sigma, c)
      | _, _ -> error "Couldn't find a second-order pattern to match"
    in aux env concl ty)

TACTIC EXTEND refine_ho
| [ "refine_ho" open_constr(c) ] ->
   [ Proofview.tclTHEN (Proofview.Unsafe.tclEVARS (fst c))
                       (refine_ho (snd c)) ]
END

TACTIC EXTEND eqns_specialize_eqs
| [ "eqns_specialize_eqs" ident(i) ] -> [
    Proofview.V82.tactic (Depelim.specialize_eqs i)
  ]
END

TACTIC EXTEND move_after_deps
| [ "move_after_deps" ident(i) constr(c) ] ->
 [ Equations_common.move_after_deps i c ]
END

(** Deriving *)

VERNAC COMMAND EXTEND Derive CLASSIFIED AS SIDEFF
| [ "Derive" ne_ident_list(ds) "for" global_list(c) ] -> [
    Derive.derive (List.map Id.to_string ds)
                  (List.map Smartlocate.global_with_alias c)
  ]
END
