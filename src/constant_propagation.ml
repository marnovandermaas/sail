(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Ast
open Ast_util
open Spec_analysis
open Type_check

(* COULD DO: dead code is only eliminated at if expressions, but we could
   also cut out impossible case branches and code after assertions. *)

(* Constant propogation.
   Takes maps of immutable/mutable variables to subsitute.
   The substs argument also contains the current type-level kid refinements
   so that we can check for dead code.
   Extremely conservative about evaluation order of assignments in
   subexpressions, dropping assignments rather than committing to
   any particular order *)


let kbindings_from_list = List.fold_left (fun s (v,i) -> KBindings.add v i s) KBindings.empty
let bindings_from_list = List.fold_left (fun s (v,i) -> Bindings.add v i s) Bindings.empty
(* union was introduced in 4.03.0, a bit too recently *)
let bindings_union s1 s2 =
  Bindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2
let kbindings_union s1 s2 =
  KBindings.merge (fun _ x y -> match x,y with
  |  _, (Some x) -> Some x
  |  (Some x), _ -> Some x
  |  _,  _ -> None) s1 s2

let rec list_extract f = function
  | [] -> None
  | h::t -> match f h with None -> list_extract f t | Some v -> Some v



let is_pure e =
  match e with
  | Effect_aux (Effect_set [],_) -> true
  | _ -> false

let remove_bound (substs,ksubsts) pat =
  let bound = bindings_from_pat pat in
  List.fold_left (fun sub v -> Bindings.remove v sub) substs bound, ksubsts

let rec is_value (E_aux (e,(l,annot))) =
  let is_constructor id =
    match destruct_tannot annot with
    | None ->
       (Reporting.print_err l "Monomorphisation"
          ("Missing type information for identifier " ^ string_of_id id);
        false) (* Be conservative if we have no info *)
    | Some (env,_,_) ->
       Env.is_union_constructor id env ||
         (match Env.lookup_id id env with
         | Enum _ -> true
         | Unbound | Local _ | Register _ -> false)
  in
  match e with
  | E_id id -> is_constructor id
  | E_lit _ -> true
  | E_tuple es | E_vector es -> List.for_all is_value es
  | E_record fes ->
     List.for_all (fun (FE_aux (FE_Fexp (_, e), _)) -> is_value e) fes
  | E_app (id,es) -> is_constructor id && List.for_all is_value es
  (* We add casts to undefined to keep the type information in the AST *)
  | E_cast (typ,E_aux (E_lit (L_aux (L_undef,_)),_)) -> true
  (* Also keep casts around records, as type inference fails without *)
  | E_cast (_, (E_aux (E_record _, _) as e')) -> is_value e'
(* TODO: more? *)
  | _ -> false

let isubst_minus_set subst set =
  IdSet.fold Bindings.remove set subst

let threaded_map f state l =
  let l',state' =
    List.fold_left (fun (tl,state) element -> let (el',state') = f state element in (el'::tl,state'))
      ([],state) l
  in List.rev l',state'


(* Attempt simple pattern matches *)
let lit_match = function
  | (L_zero | L_false), (L_zero | L_false) -> true
  | (L_one  | L_true ), (L_one  | L_true ) -> true
  | L_num i1, L_num i2 -> Big_int.equal i1 i2
  | l1,l2 -> l1 = l2

(* There's no undefined nexp, so replace undefined sizes with a plausible size.
   32 is used as a sensible default. *)

let fabricate_nexp_exist env l typ kids nc typ' =
  match kids,nc,Env.expand_synonyms env typ' with
  | ([kid],NC_aux (NC_set (kid',i::_),_),
     Typ_aux (Typ_app (Id_aux (Id "atom",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_)]),_))
      when Kid.compare kid kid' = 0 && Kid.compare kid kid'' = 0 ->
     Nexp_aux (Nexp_constant i,Unknown)
  | ([kid],NC_aux (NC_true,_),
     Typ_aux (Typ_app (Id_aux (Id "atom",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_)]),_))
      when Kid.compare kid kid'' = 0 ->
     nint 32
  | ([kid],NC_aux (NC_set (kid',i::_),_),
     Typ_aux (Typ_app (Id_aux (Id "range",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_);
                        A_aux (A_nexp (Nexp_aux (Nexp_var kid''',_)),_)]),_))
      when Kid.compare kid kid' = 0 && Kid.compare kid kid'' = 0 &&
        Kid.compare kid kid''' = 0 ->
     Nexp_aux (Nexp_constant i,Unknown)
  | ([kid],NC_aux (NC_true,_),
     Typ_aux (Typ_app (Id_aux (Id "range",_),
                       [A_aux (A_nexp (Nexp_aux (Nexp_var kid'',_)),_);
                        A_aux (A_nexp (Nexp_aux (Nexp_var kid''',_)),_)]),_))
      when Kid.compare kid kid'' = 0 &&
        Kid.compare kid kid''' = 0 ->
     nint 32
  | ([], _, typ) -> nint 32
  | (kids, nc, typ) ->
     raise (Reporting.err_general l
              ("Undefined value at unsupported type " ^ string_of_typ typ ^ " with " ^ Util.string_of_list ", " string_of_kid kids))

let fabricate_nexp l tannot =
  match destruct_tannot tannot with
  | None -> nint 32
  | Some (env,typ,_) ->
     match Type_check.destruct_exist (Type_check.Env.expand_synonyms env typ) with
     | None -> nint 32
     (* TODO: check this *)
     | Some (kopts,nc,typ') -> fabricate_nexp_exist env l typ (List.map kopt_kid kopts) nc typ'

let atom_typ_kid kid = function
  | Typ_aux (Typ_app (Id_aux (Id "atom",_),
                      [A_aux (A_nexp (Nexp_aux (Nexp_var kid',_)),_)]),_) ->
     Kid.compare kid kid' = 0
  | _ -> false

(* We reduce casts in a few cases, in particular to ensure that where the
   type checker has added a ({'n, true. atom('n)}) ex_int(...) cast we can
   fill in the 'n.  For undefined we fabricate a suitable value for 'n. *)

let reduce_cast typ exp l annot =
  let env = env_of_annot (l,annot) in
  let typ' = Env.base_typ_of env typ in
  match exp, destruct_exist (Env.expand_synonyms env typ') with
  | E_aux (E_lit (L_aux (L_num n,_)),_), Some ([kopt],nc,typ'') when atom_typ_kid (kopt_kid kopt) typ'' ->
     let nc_env = Env.add_typ_var l kopt env in
     let nc_env = Env.add_constraint (nc_eq (nvar (kopt_kid kopt)) (nconstant n)) nc_env in
     if prove __POS__ nc_env nc
     then exp
     else raise (Reporting.err_unreachable l __POS__
                   ("Constant propagation error: literal " ^ Big_int.to_string n ^
                       " does not satisfy constraint " ^ string_of_n_constraint nc))
  | E_aux (E_lit (L_aux (L_undef,_)),_), Some ([kopt],nc,typ'') when atom_typ_kid (kopt_kid kopt) typ'' ->
     let nexp = fabricate_nexp_exist env Unknown typ [kopt_kid kopt] nc typ'' in
     let newtyp = subst_kids_typ (KBindings.singleton (kopt_kid kopt) nexp) typ'' in
     E_aux (E_cast (newtyp, exp), (Generated l,replace_typ newtyp annot))
  | E_aux (E_cast (_,
                   (E_aux (E_lit (L_aux (L_undef,_)),_) as exp)),_),
     Some ([kopt],nc,typ'') when atom_typ_kid (kopt_kid kopt) typ'' ->
     let nexp = fabricate_nexp_exist env Unknown typ [kopt_kid kopt] nc typ'' in
     let newtyp = subst_kids_typ (KBindings.singleton (kopt_kid kopt) nexp) typ'' in
     E_aux (E_cast (newtyp, exp), (Generated l,replace_typ newtyp annot))
  | _ -> E_aux (E_cast (typ,exp),(l,annot))

(* Used for constant propagation in pattern matches *)
type 'a matchresult =
  | DoesMatch of 'a
  | DoesNotMatch
  | GiveUp

(* Remove top-level casts from an expression.  Useful when we need to look at
   subexpressions to reduce something, but could break type-checking if we used
   it everywhere. *)
let rec drop_casts = function
  | E_aux (E_cast (_,e),_) -> drop_casts e
  | exp -> exp

let int_of_str_lit = function
  | L_hex hex -> Big_int.of_string ("0x" ^ hex)
  | L_bin bin -> Big_int.of_string ("0b" ^ bin)
  | _ -> assert false

let bits_of_lit = function
  | L_bin bin -> bin
  | L_hex hex -> hex_to_bin hex
  | _ -> assert false

let slice_lit (L_aux (lit,ll)) i len (Ord_aux (ord,_)) =
  let i = Big_int.to_int i in
  let len = Big_int.to_int len in
  let bin = bits_of_lit lit in
  match match ord with
  | Ord_inc -> Some i
  | Ord_dec -> Some (String.length bin - i - len)
  | Ord_var _ -> None
  with
  | None -> None
  | Some i ->
     Some (L_aux (L_bin (String.sub bin i len),Generated ll))

let concat_vec lit1 lit2 =
  let bits1 = bits_of_lit lit1 in
  let bits2 = bits_of_lit lit2 in
  L_bin (bits1 ^ bits2)

let lit_eq (L_aux (l1,_)) (L_aux (l2,_)) =
  match l1,l2 with
  | (L_zero|L_false), (L_zero|L_false)
  | (L_one |L_true ), (L_one |L_true)
    -> Some true
  | (L_hex _| L_bin _), (L_hex _|L_bin _)
    -> Some (Big_int.equal (int_of_str_lit l1) (int_of_str_lit l2))
  | L_undef, _ | _, L_undef -> None
  | L_num i1, L_num i2 -> Some (Big_int.equal i1 i2)
  | _ -> Some (l1 = l2)

let construct_lit_vector args =
  let rec aux l = function
    | [] -> Some (L_aux (L_bin (String.concat "" (List.rev l)),Unknown))
    | E_aux (E_lit (L_aux ((L_zero | L_one) as lit,_)),_)::t ->
       aux ((if lit = L_zero then "0" else "1")::l) t
    | _ -> None
  in aux [] args

(* Add a cast to undefined so that it retains its type, otherwise it can't be
   substituted safely *)
let keep_undef_typ value =
  let e_aux (e, ann) =
    match e with
    | E_lit (L_aux (L_undef, _)) ->
       (* Add cast to undefined... *)
       E_aux (E_cast (typ_of_annot ann, E_aux (e, ann)), ann)
    | E_cast (typ, E_aux (E_cast (_, e), _)) ->
       (* ... unless there was a cast already *)
       E_aux (E_cast (typ, e), ann)
    | _ -> E_aux (e, ann)
  in
  let open Rewriter in
  fold_exp { id_algebra with e_aux = e_aux } value

(* Check whether the current environment with the given kid assignments is
   inconsistent (and hence whether the code is dead) *)
let is_env_inconsistent env ksubsts =
  let env = KBindings.fold (fun k nexp env ->
    Env.add_constraint (nc_eq (nvar k) nexp) env) ksubsts env in
  prove __POS__ env nc_false

module StringSet = Set.Make(String)
module StringMap = Map.Make(String)

let const_props target defs ref_vars =
  let const_fold exp =
    (* Constant-fold function applications with constant arguments *)
    let interpreter_istate =
      (* Do not interpret undefined_X functions *)
      let open Interpreter in
      let undefined_builtin_ids = ids_of_defs (Defs Initial_check.undefined_builtin_val_specs) in
      let remove_primop id = StringMap.remove (string_of_id id) in
      let remove_undefined_primops = IdSet.fold remove_primop undefined_builtin_ids in
      let (lstate, gstate) = Constant_fold.initial_state defs Type_check.initial_env in
      (lstate, { gstate with primops = remove_undefined_primops gstate.primops })
    in
    try
      strip_exp exp
      |> infer_exp (env_of exp)
      |> Constant_fold.rewrite_exp_once target interpreter_istate
      |> keep_undef_typ
    with
    | _ -> exp
  in
  let constants =
    let add m = function
      | DEF_val (LB_aux (LB_val (P_aux ((P_id id | P_typ (_,P_aux (P_id id,_))),_), exp),_))
           when Constant_fold.is_constant exp ->
         Bindings.add id exp m
      | _ -> m
    in
    match defs with
    | Defs defs ->
       List.fold_left add Bindings.empty defs
  in
  let replace_constant (E_aux (e,annot) as exp) =
    match e with
    | E_id id ->
       (match Bindings.find_opt id constants with
        | Some e -> e
        | None -> exp)
    | _ -> exp
  in
  let rec const_prop_exp substs assigns ((E_aux (e,(l,annot))) as exp) =
    (* Functions to treat lists and tuples of subexpressions as possibly
       non-deterministic: that is, we stop making any assumptions about
       variables that are assigned to in any of the subexpressions *)
    let non_det_exp_list es =
      let assigned_in =
        List.fold_left (fun vs exp -> IdSet.union vs (assigned_vars exp))
          IdSet.empty es in
      let assigns = isubst_minus_set assigns assigned_in in
      let es' = List.map (fun e -> fst (const_prop_exp substs assigns e)) es in
      es',assigns
    in
    let non_det_exp_2 e1 e2 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigns = isubst_minus_set assigns assigned_in_e12 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       e1',e2',assigns
    in
    let non_det_exp_3 e1 e2 e3 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigned_in_e123 = IdSet.union assigned_in_e12 (assigned_vars e3) in
       let assigns = isubst_minus_set assigns assigned_in_e123 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       let e3',_ = const_prop_exp substs assigns e3 in
       e1',e2',e3',assigns
    in
    let non_det_exp_4 e1 e2 e3 e4 =
       let assigned_in_e12 = IdSet.union (assigned_vars e1) (assigned_vars e2) in
       let assigned_in_e123 = IdSet.union assigned_in_e12 (assigned_vars e3) in
       let assigned_in_e1234 = IdSet.union assigned_in_e123 (assigned_vars e4) in
       let assigns = isubst_minus_set assigns assigned_in_e1234 in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       let e3',_ = const_prop_exp substs assigns e3 in
       let e4',_ = const_prop_exp substs assigns e4 in
       e1',e2',e3',e4',assigns
    in
    let rewrap e = E_aux (e,(l,annot)) in
    let re e assigns = rewrap e,assigns in
    match e with
      (* TODO: are there more circumstances in which we should get rid of these? *)
    | E_block [e] -> const_prop_exp substs assigns e
    | E_block es ->
       let es',assigns = threaded_map (const_prop_exp substs) assigns es in
       re (E_block es') assigns
    | E_id id ->
       let env = Type_check.env_of_annot (l, annot) in
       (try
         match Env.lookup_id id env with
         | Local (Immutable,_) -> Bindings.find id (fst substs)
         | Local (Mutable,_)   -> Bindings.find id assigns
         | _ -> exp
       with Not_found -> exp),assigns
    | E_lit _
    | E_sizeof _
    | E_constraint _
      -> exp,assigns
    | E_cast (t,e') ->
       let e'',assigns = const_prop_exp substs assigns e' in
       if is_value e''
       then reduce_cast t e'' l annot, assigns
       else re (E_cast (t, e'')) assigns
    | E_app (id,es) ->
       let es',assigns = non_det_exp_list es in
       let env = Type_check.env_of_annot (l, annot) in
       const_prop_try_fn env (id, es') (l, annot), assigns
    | E_tuple es ->
       let es',assigns = non_det_exp_list es in
       re (E_tuple es') assigns
    | E_if (e1,e2,e3) ->
       let e1',assigns = const_prop_exp substs assigns e1 in
       let e1_no_casts = drop_casts e1' in
       (match e1_no_casts with
       | E_aux (E_lit (L_aux ((L_true|L_false) as lit ,_)),_) ->
          (match lit with
          | L_true -> const_prop_exp substs assigns e2
          |  _     -> const_prop_exp substs assigns e3)
       | _ ->
          (* If the guard is an equality check, propagate the value. *)
          let env1 = env_of e1_no_casts in
          let is_equal id =
            List.exists (fun id' -> Id.compare id id' == 0)
              (Env.get_overloads (Id_aux (Operator "==", Parse_ast.Unknown))
                 env1)
          in
          let substs_true =
            match e1_no_casts with
            | E_aux (E_app (id, [E_aux (E_id var,_); vl]),_)
            | E_aux (E_app (id, [vl; E_aux (E_id var,_)]),_)
                when is_equal id ->
               if is_value vl then
                 (match Env.lookup_id var env1 with
                 | Local (Immutable,_) -> Bindings.add var vl (fst substs),snd substs
                 | _ -> substs)
               else substs
            | _ -> substs
          in
          (* Discard impossible branches *)
          if is_env_inconsistent (env_of e2) (snd substs) then
            const_prop_exp substs assigns e3
          else if is_env_inconsistent (env_of e3) (snd substs) then
            const_prop_exp substs_true assigns e2
          else
            let e2',assigns2 = const_prop_exp substs_true assigns e2 in
            let e3',assigns3 = const_prop_exp substs assigns e3 in
            let assigns = isubst_minus_set assigns (assigned_vars e2) in
            let assigns = isubst_minus_set assigns (assigned_vars e3) in
            re (E_if (e1',e2',e3')) assigns)
    | E_for (id,e1,e2,e3,ord,e4) ->
       (* Treat e1, e2 and e3 (from, to and by) as a non-det tuple *)
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       let assigns = isubst_minus_set assigns (assigned_vars e4) in
       let e4',_ = const_prop_exp (Bindings.remove id (fst substs),snd substs) assigns e4 in
       re (E_for (id,e1',e2',e3',ord,e4')) assigns
    | E_loop (loop,m,e1,e2) ->
       let assigns = isubst_minus_set assigns (IdSet.union (assigned_vars e1) (assigned_vars e2)) in
       let m' = match m with
         | Measure_aux (Measure_none,_) -> m
         | Measure_aux (Measure_some exp,l) ->
            let exp',_ = const_prop_exp substs assigns exp in
            Measure_aux (Measure_some exp',l)
       in
       let e1',_ = const_prop_exp substs assigns e1 in
       let e2',_ = const_prop_exp substs assigns e2 in
       re (E_loop (loop,m',e1',e2')) assigns
    | E_vector es ->
       let es',assigns = non_det_exp_list es in
       begin
         match construct_lit_vector es' with
         | None -> re (E_vector es') assigns
         | Some lit -> re (E_lit lit) assigns
       end
    | E_vector_access (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_vector_access (e1',e2')) assigns
    | E_vector_subrange (e1,e2,e3) ->
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       re (E_vector_subrange (e1',e2',e3')) assigns
    | E_vector_update (e1,e2,e3) ->
       let e1',e2',e3',assigns = non_det_exp_3 e1 e2 e3 in
       re (E_vector_update (e1',e2',e3')) assigns
    | E_vector_update_subrange (e1,e2,e3,e4) ->
       let e1',e2',e3',e4',assigns = non_det_exp_4 e1 e2 e3 e4 in
       re (E_vector_update_subrange (e1',e2',e3',e4')) assigns
    | E_vector_append (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_vector_append (e1',e2')) assigns
    | E_list es ->
       let es',assigns = non_det_exp_list es in
       re (E_list es') assigns
    | E_cons (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_cons (e1',e2')) assigns
    | E_record fes ->
       let assigned_in_fes = assigned_vars_in_fexps fes in
       let assigns = isubst_minus_set assigns assigned_in_fes in
       re (E_record (const_prop_fexps substs assigns fes)) assigns
    | E_record_update (e,fes) ->
       let assigned_in = IdSet.union (assigned_vars_in_fexps fes) (assigned_vars e) in
       let assigns = isubst_minus_set assigns assigned_in in
       let e',_ = const_prop_exp substs assigns e in
       let fes' = const_prop_fexps substs assigns fes in
       begin
         match unaux_exp (fst (uncast_exp e')) with
         | E_record (fes0) ->
            let apply_fexp (FE_aux (FE_Fexp (id, e), _)) (FE_aux (FE_Fexp (id', e'), ann)) =
              if Id.compare id id' = 0 then
                FE_aux (FE_Fexp (id', e), ann)
              else
                FE_aux (FE_Fexp (id', e'), ann)
            in
            let update_fields fexp = List.map (apply_fexp fexp) in
            let fes0' = List.fold_right update_fields fes' fes0 in
            re (E_record fes0') assigns
         | _ ->
            re (E_record_update (e', fes')) assigns
       end
    | E_field (e,id) ->
       let e',assigns = const_prop_exp substs assigns e in
       begin
         let is_field (FE_aux (FE_Fexp (id', _), _)) = Id.compare id id' = 0 in
         match unaux_exp e' with
         | E_record fes0 when List.exists is_field fes0 ->
            let (FE_aux (FE_Fexp (_, e), _)) = List.find is_field fes0 in
            re (unaux_exp e) assigns
         | _ ->
            re (E_field (e',id)) assigns
       end
    | E_case (e,cases) ->
       let e',assigns = const_prop_exp substs assigns e in
       (match can_match e' cases substs assigns with
       | None ->
          let assigned_in =
            List.fold_left (fun vs pe -> IdSet.union vs (assigned_vars_in_pexp pe))
              IdSet.empty cases
          in
          let assigns' = isubst_minus_set assigns assigned_in in
          re (E_case (e', List.map (const_prop_pexp substs assigns) cases)) assigns'
       | Some (E_aux (_,(_,annot')) as exp,newbindings,kbindings) ->
          let exp = nexp_subst_exp (kbindings_from_list kbindings) exp in
          let newbindings_env = bindings_from_list newbindings in
          let substs' = bindings_union (fst substs) newbindings_env, snd substs in
          const_prop_exp substs' assigns exp)
    | E_let (lb,e2) ->
       begin
         match lb with
         | LB_aux (LB_val (p,e), annot) ->
            let e',assigns = const_prop_exp substs assigns e in
            let substs' = remove_bound substs p in
            let plain () =
              let e2',assigns = const_prop_exp substs' assigns e2 in
              re (E_let (LB_aux (LB_val (p,e'), annot),
                         e2')) assigns in
            if is_value e' then
              match can_match e' [Pat_aux (Pat_case (p,[],e2),Unknown)] substs assigns with
              | None -> plain ()
              | Some (e'',bindings,kbindings) ->
                 let e'' = nexp_subst_exp (kbindings_from_list kbindings) e'' in
                 let bindings = bindings_from_list bindings in
                 let substs'' = bindings_union (fst substs') bindings, snd substs' in
                 const_prop_exp substs'' assigns e''
            else plain ()
       end
    (* TODO maybe - tuple assignments *)
    | E_assign (le,e) ->
       let env = Type_check.env_of_annot (l, annot) in
       let assigned_in = IdSet.union (assigned_vars_in_lexp le) (assigned_vars e) in
       let assigns = isubst_minus_set assigns assigned_in in
       let le',idopt = const_prop_lexp substs assigns le in
       let e',_ = const_prop_exp substs assigns e in
       let assigns =
         match idopt with
         | Some id ->
            begin
              match Env.lookup_id id env with
              | Local (Mutable,_) | Unbound ->
                 if is_value e' && not (IdSet.mem id ref_vars)
                 then Bindings.add id (keep_undef_typ e') assigns
                 else Bindings.remove id assigns
              | _ -> assigns
            end
         | None -> assigns
       in
       re (E_assign (le', e')) assigns
    | E_exit e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_exit e') Bindings.empty
    | E_ref id -> re (E_ref id) Bindings.empty
    | E_throw e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_throw e') Bindings.empty
    | E_try (e,cases) ->
       (* TODO: try and preserve *any* assignment info *)
       let e',_ = const_prop_exp substs assigns e in
       re (E_case (e', List.map (const_prop_pexp substs Bindings.empty) cases)) Bindings.empty
    | E_return e ->
       let e',_ = const_prop_exp substs assigns e in
       re (E_return e') Bindings.empty
    | E_assert (e1,e2) ->
       let e1',e2',assigns = non_det_exp_2 e1 e2 in
       re (E_assert (e1',e2')) assigns

    | E_app_infix _
    | E_var _
    | E_internal_plet _
    | E_internal_return _
    | E_internal_value _
      -> raise (Reporting.err_unreachable l __POS__
                  ("Unexpected expression encountered in monomorphisation: " ^ string_of_exp exp))
  and const_prop_fexps substs assigns fes =
    List.map (const_prop_fexp substs assigns) fes
  and const_prop_fexp substs assigns (FE_aux (FE_Fexp (id,e), annot)) =
    FE_aux (FE_Fexp (id,fst (const_prop_exp substs assigns e)),annot)
  and const_prop_pexp substs assigns = assert false (* FIXME function
    | (Pat_aux (Pat_exp (p,e),l)) ->
       Pat_aux (Pat_exp (p,fst (const_prop_exp (remove_bound substs p) assigns e)),l)
    | (Pat_aux (Pat_when (p,e1,e2),l)) ->
       let substs' = remove_bound substs p in
       let e1',assigns = const_prop_exp substs' assigns e1 in
       Pat_aux (Pat_when (p, e1', fst (const_prop_exp substs' assigns e2)),l) *)
  and const_prop_lexp substs assigns ((LEXP_aux (e,annot)) as le) =
    let re e = LEXP_aux (e,annot), None in
    match e with
    | LEXP_id id (* shouldn't end up substituting here *)
    | LEXP_cast (_,id)
      -> le, Some id
    | LEXP_memory (id,es) ->
       re (LEXP_memory (id,List.map (fun e -> fst (const_prop_exp substs assigns e)) es)) (* or here *)
    | LEXP_tup les -> re (LEXP_tup (List.map (fun le -> fst (const_prop_lexp substs assigns le)) les))
    | LEXP_vector (le,e) -> re (LEXP_vector (fst (const_prop_lexp substs assigns le), fst (const_prop_exp substs assigns e)))
    | LEXP_vector_range (le,e1,e2) ->
       re (LEXP_vector_range (fst (const_prop_lexp substs assigns le),
                              fst (const_prop_exp substs assigns e1),
                              fst (const_prop_exp substs assigns e2)))
    | LEXP_vector_concat les -> re (LEXP_vector_concat (List.map (fun le -> fst (const_prop_lexp substs assigns le)) les))
    | LEXP_field (le,id) -> re (LEXP_field (fst (const_prop_lexp substs assigns le), id))
    | LEXP_deref e ->
       re (LEXP_deref (fst (const_prop_exp substs assigns e)))
  (* Try to evaluate function calls with constant arguments via
     (interpreter-based) constant folding.
     Boolean connectives are special-cased to support short-circuiting when one
     argument has a suitable value (even if the other one is not constant).
     Moreover, calls to a __size function (in particular generated by sizeof
     rewriting) with a known-constant return type are replaced by that constant;
     e.g., (length(op : bits(32)) : int(32)) becomes 32 even if op is not constant.
  *)
  and const_prop_try_fn env (id, args) (l, annot) =
    let exp_orig = E_aux (E_app (id, args), (l, annot)) in
    let args = List.map replace_constant args in
    let exp = E_aux (E_app (id, args), (l, annot)) in
    let rec is_overload_of f =
      Env.get_overloads f env
      |> List.exists (fun id' -> Id.compare id id' = 0 || is_overload_of id')
    in
    match (string_of_id id, args) with
    | "and_bool", ([E_aux (E_lit (L_aux (L_false, _)), _) as e_false; _] |
                   [_; E_aux (E_lit (L_aux (L_false, _)), _) as e_false]) ->
       e_false
    | "or_bool", ([E_aux (E_lit (L_aux (L_true, _)), _) as e_true; _] |
                  [_; E_aux (E_lit (L_aux (L_true, _)), _) as e_true]) ->
       e_true
    | _, _ when List.for_all Constant_fold.is_constant args ->
       const_fold exp
    | _, [arg] when is_overload_of (mk_id "__size") ->
       (match destruct_atom_nexp env (typ_of exp) with
        | Some (Nexp_aux (Nexp_constant i, _)) ->
           E_aux (E_lit (mk_lit (L_num i)), (l, annot))
        | _ -> exp_orig)
    | _ -> exp_orig

  and can_match_with_env env (E_aux (e,(l,annot)) as exp0) cases (substs,ksubsts) assigns =
    let rec check_exp_pat (E_aux (e,(l,annot)) as exp) (P_aux (p,(l',_)) as pat) =
      match e, p with
      | _, P_wild -> DoesMatch ([],[])
      | _, P_typ (_,p') -> check_exp_pat exp p'
      | _, P_id id' when pat_id_is_variable env id' ->
         let exp_typ = typ_of exp in
         let pat_typ = typ_of_pat pat in
         let goals = KidSet.diff (tyvars_of_typ pat_typ) (tyvars_of_typ exp_typ) in
         let unifiers =
           try Type_check.unify l env goals pat_typ exp_typ
           with _ -> KBindings.empty in
         let is_nexp (k,a) = match a with
           | A_aux (A_nexp n,_) -> Some (k,n)
           | _ -> None
         in
         let kbindings = Util.map_filter is_nexp (KBindings.bindings unifiers) in
         DoesMatch ([id',exp],kbindings)
      | E_tuple es, P_tup ps ->
         let rec check = function
           | DoesNotMatch -> fun _ -> DoesNotMatch
           | GiveUp -> fun _ -> GiveUp
           | DoesMatch (s,ns) ->
              fun (e,p) ->
              match check_exp_pat e p with
              | DoesMatch (s',ns') -> DoesMatch (s@s', ns@ns')
              | x -> x
         in List.fold_left check (DoesMatch ([],[])) (List.combine es ps)
      | E_id id, _ ->
         (match Env.lookup_id id env with
         | Enum _ -> begin
            match p with
            | P_id id'
            | P_app (id',[]) ->
               if Id.compare id id' = 0 then DoesMatch ([],[]) else DoesNotMatch
            | _ ->
               (Reporting.print_err l' "Monomorphisation"
                  "Unexpected kind of pattern for enumeration"; GiveUp)
           end
         | _ -> GiveUp)
      | E_lit (L_aux (lit_e, lit_l)), P_lit (L_aux (lit_p, _)) ->
         if lit_match (lit_e,lit_p) then DoesMatch ([],[]) else DoesNotMatch
      | E_lit (L_aux (lit_e, lit_l)),
        P_var (P_aux (P_id id,p_id_annot), TP_aux (TP_var kid, _)) ->
         begin
           match lit_e with
           | L_num i ->
              DoesMatch ([id, E_aux (e,(l,annot))],
                         [kid,Nexp_aux (Nexp_constant i,Unknown)])
           (* For undefined we fix the type-level size (because there's no good
              way to construct an undefined size), but leave the term as undefined
              to make the meaning clear. *)
           | L_undef ->
              let nexp = fabricate_nexp l annot in
              let typ = subst_kids_typ (KBindings.singleton kid nexp) (typ_of_annot p_id_annot) in
              DoesMatch ([id, E_aux (E_cast (typ,E_aux (e,(l,empty_tannot))),(l,empty_tannot))],
                         [kid,nexp])
           | _ ->
              (Reporting.print_err lit_l "Monomorphisation"
                 "Unexpected kind of literal for var match"; GiveUp)
         end
      | E_lit _, _ ->
         (Reporting.print_err l' "Monomorphisation"
            "Unexpected kind of pattern for literal"; GiveUp)
      | E_vector es, P_vector ps
           when List.for_all (function (E_aux (E_lit _,_)) -> true | _ -> false) es ->
         let matches = List.map2 (fun e p ->
           match e, p with
           | E_aux (E_lit (L_aux (lit,_)),_), P_aux (P_lit (L_aux (lit',_)),_) ->
              if lit_match (lit,lit') then DoesMatch ([],[]) else DoesNotMatch
           | E_aux (E_lit l,_), P_aux (P_id var,_) when pat_id_is_variable env var ->
              DoesMatch ([var, e],[])
           | _ -> GiveUp) es ps in
         let final = List.fold_left (fun acc m -> match acc, m with
           | _, GiveUp -> GiveUp
           | GiveUp, _ -> GiveUp
           | DoesMatch (sub,ksub), DoesMatch(sub',ksub') -> DoesMatch(sub@sub',ksub@ksub')
           | _ -> DoesNotMatch) (DoesMatch ([],[])) matches in
         (match final with
         | GiveUp ->
            (Reporting.print_err l "Monomorphisation"
               "Unexpected kind of pattern for vector literal"; GiveUp)
         | _ -> final)
      | E_vector _, _ ->
         (Reporting.print_err l "Monomorphisation"
            "Unexpected kind of pattern for vector literal"; GiveUp)
      | E_cast (undef_typ, (E_aux (E_lit (L_aux (L_undef, lit_l)),_) as e_undef)),
        P_lit (L_aux (lit_p, _))
        -> DoesNotMatch
      | E_cast (undef_typ, (E_aux (E_lit (L_aux (L_undef, lit_l)),_) as e_undef)),
        P_var (P_aux (P_id id,p_id_annot), TP_aux (TP_var kid, _)) ->
           (* For undefined we fix the type-level size (because there's no good
              way to construct an undefined size), but leave the term as undefined
              to make the meaning clear. *)
         let nexp = fabricate_nexp l annot in
         let kids = equal_kids (env_of_annot p_id_annot) kid in
         let ksubst = KidSet.fold (fun k b -> KBindings.add k nexp b) kids KBindings.empty in
         let typ = subst_kids_typ ksubst (typ_of_annot p_id_annot) in
         DoesMatch ([id, E_aux (E_cast (typ,e_undef),(l,empty_tannot))],
                    KBindings.bindings ksubst)
      | E_cast (undef_typ, (E_aux (E_lit (L_aux (L_undef, lit_l)),_) as e_undef)), _ ->
             (Reporting.print_err l' "Monomorphisation"
                "Unexpected kind of pattern for literal"; GiveUp)
      | E_record _,_ | E_cast (_, E_aux (E_record _, _)),_ -> DoesNotMatch
      | _ -> GiveUp
    in
    let check_pat = check_exp_pat exp0 in
    let rec findpat_generic description assigns = function
      | [] -> (Reporting.print_err l "Monomorphisation"
                                   ("Failed to find a case for " ^ description); None)
      (* FIXME
      | (Pat_aux (Pat_when (p,guard,exp),_))::tl -> begin
        match check_pat p with
        | DoesNotMatch -> findpat_generic description assigns tl
        | DoesMatch (vsubst,ksubst) -> begin
          let guard = nexp_subst_exp (kbindings_from_list ksubst) guard in
          let substs = bindings_union substs (bindings_from_list vsubst),
                       kbindings_union ksubsts (kbindings_from_list ksubst) in
          let (E_aux (guard,_)),assigns = const_prop_exp substs assigns guard in
          match guard with
          | E_lit (L_aux (L_true,_)) -> Some (exp,vsubst,ksubst)
          | E_lit (L_aux (L_false,_)) -> findpat_generic description assigns tl
          | _ -> None
        end
        | GiveUp -> None
      end
      | (Pat_aux (Pat_exp (p,exp),_))::tl ->
         match check_pat p with
         | DoesNotMatch -> findpat_generic description assigns tl
         | DoesMatch (subst,ksubst) -> Some (exp,subst,ksubst)
         | GiveUp -> None *)
    in findpat_generic (string_of_exp exp0) assigns cases

  and can_match exp =
    let env = Type_check.env_of exp in
    can_match_with_env env exp

in (const_prop_exp, const_prop_pexp)

let const_prop target d r = fst (const_props target d r)
let const_prop_pexp target d r = snd (const_props target d r)

let referenced_vars exp =
  let open Rewriter in
  fst (fold_exp
         { (compute_algebra IdSet.empty IdSet.union) with
           e_ref = (fun id -> IdSet.singleton id, E_ref id) } exp)

(* This is intended to remove impossible cases when a type-level constant has
   been used to fix a property of the architecture.  In particular, the current
   version of the RISC-V model uses constructs like

   match (width, sizeof(xlen)) {
     (BYTE, _)    => ...
     ...
     (DOUBLE, 64) => ...
   };

   and the type checker will replace the sizeof with the literal 32 or 64.  This
   pass will then remove the DOUBLE case.

   It would be nice to have the full constant propagation above do this kind of
   thing too...
*)

let remove_impossible_int_cases _ =
  let must_keep_case exp (Pat_aux (Pat_case (p,_,_),_)) =
    let rec aux (E_aux (exp,_)) (P_aux (p,_)) =
      match exp, p with
      | E_tuple exps, P_tup ps -> List.for_all2 aux exps ps
      | E_lit (L_aux (lit,_)), P_lit (L_aux (lit',_)) -> lit_match (lit, lit')
      | _ -> true
    in aux exp p
  in
  let e_case (exp,cases) =
    E_case (exp, List.filter (must_keep_case exp) cases)
  in
  let e_if (cond, e_then, e_else) =
    match destruct_atom_bool (env_of cond) (typ_of cond) with
    | Some nc ->
       if prove __POS__ (env_of cond) nc then unaux_exp e_then else
       if prove __POS__ (env_of cond) (nc_not nc) then unaux_exp e_else else
       E_if (cond, e_then, e_else)
    | _ -> E_if (cond, e_then, e_else)
  in
  let open Rewriter in
  let rewrite_exp _ = fold_exp { id_algebra with e_case = e_case; e_if = e_if } in
  rewrite_defs_base { rewriters_base with rewrite_exp = rewrite_exp }

