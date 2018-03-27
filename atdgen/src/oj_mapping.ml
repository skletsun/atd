open Atd.Ast
open Error
open Mapping

type o = Ocaml.atd_ocaml_repr
type j = Json.json_repr

type oj_mapping =
    (Ocaml.atd_ocaml_repr, Json.json_repr) Mapping.mapping

(*
  Translation of the types into the ocaml/json mapping.
*)

let rec mapping_of_expr (x : type_expr) : oj_mapping =
  match x with
      `Sum (loc, l, an) ->
        let ocaml_t = `Sum (Ocaml.get_ocaml_sum an) in
        let json_t = `Sum in
        `Sum (loc, Array.of_list (List.map mapping_of_variant l),
              ocaml_t, json_t)

    | `Record (loc, l, an) ->
        let ocaml_t = `Record (Ocaml.get_ocaml_record an) in
        let ocaml_field_prefix = Ocaml.get_ocaml_field_prefix an in
        let json_t = `Record (Json.get_json_record an) in
        `Record (loc,
                 Array.of_list
                   (List.map (mapping_of_field ocaml_field_prefix) l),
                 ocaml_t, json_t)

    | `Tuple (loc, l, _) ->
        let ocaml_t = `Tuple in
        let json_t = `Tuple in
        `Tuple (loc, Array.of_list (List.map mapping_of_cell l),
                ocaml_t, json_t)

    | `List (loc, x, an) ->
        let ocaml_t = `List (Ocaml.get_ocaml_list an) in
        let json_t = `List (Json.get_json_list an) in
        `List (loc, mapping_of_expr x, ocaml_t, json_t)

    | `Option (loc, x, _) ->
        let ocaml_t = `Option in
        let json_t = `Option in
        `Option (loc, mapping_of_expr x, ocaml_t, json_t)

    | `Nullable (loc, x, _) ->
        let ocaml_t = `Nullable in
        let json_t = `Nullable in
        `Nullable (loc, mapping_of_expr x, ocaml_t, json_t)

    | `Shared (loc, _, _) ->
        error loc "Sharing is not supported by the JSON interface"

    | `Wrap (loc, x, an) ->
        let ocaml_t = `Wrap (Ocaml.get_ocaml_wrap loc an) in
        let json_t = `Wrap in
        `Wrap (loc, mapping_of_expr x, ocaml_t, json_t)

    | `Name (loc, (_, s, l), an) ->
        (match s with
             "unit" ->
               `Unit (loc, `Unit, `Unit)
           | "bool" ->
               `Bool (loc, `Bool, `Bool)
           | "int" ->
               let o = Ocaml.get_ocaml_int an in
               `Int (loc, `Int o, `Int)
           | "float" ->
               let j = Json.get_json_float an in
               `Float (loc, `Float, `Float j)
           | "string" ->
               `String (loc, `String, `String)
           | s ->
               `Name (loc, s, List.map mapping_of_expr l, None, None)
        )
    | `Tvar (loc, s) ->
        `Tvar (loc, s)

and mapping_of_cell (loc, x, an) =
  let default = Ocaml.get_ocaml_default an in
  let doc = Doc.get_doc loc an in
  let ocaml_t =
    `Cell {
      Ocaml.ocaml_default = default;
      ocaml_fname = "";
      ocaml_mutable = false;
      ocaml_fdoc = doc;
    }
  in
  let json_t = `Cell in
  {
    cel_loc = loc;
    cel_value = mapping_of_expr x;
    cel_arepr = ocaml_t;
    cel_brepr = json_t
  }


and mapping_of_variant = function
    `Variant (loc, (s, an), o) ->
      let ocaml_cons = Ocaml.get_ocaml_cons s an in
      let doc = Doc.get_doc loc an in
      let ocaml_t =
        `Variant {
          Ocaml.ocaml_cons = ocaml_cons;
          ocaml_vdoc = doc;
        }
      in
      let json_t =
        if Json.get_json_untyped an
        then `Variant { Json.json_cons = None; }
        else
          let json_cons = Json.get_json_cons s an in
          `Variant { Json.json_cons = Some json_cons; }
      in
      let arg =
        match o with
            None -> None
          | Some x -> Some (mapping_of_expr x) in
      {
        var_loc = loc;
        var_cons = s;
        var_arg = arg;
        var_arepr = ocaml_t;
        var_brepr = json_t
      }

  | `Inherit _ -> assert false

and mapping_of_field ocaml_field_prefix = function
    `Field (loc, (s, fk, an), x) ->
      let fvalue = mapping_of_expr x in
      let ocaml_default, json_unwrapped =
       match fk, Ocaml.get_ocaml_default an with
           `Required, None -> None, false
         | `Optional, None -> Some "None", true
         | (`Required | `Optional), Some _ ->
             error loc "Superfluous default OCaml value"
         | `With_default, Some s -> Some s, false
         | `With_default, None ->
             (* will try to determine implicit default value later *)
             None, false
      in
      let ocaml_fname = Ocaml.get_ocaml_fname (ocaml_field_prefix ^ s) an in
      let ocaml_mutable = Ocaml.get_ocaml_mutable an in
      let doc = Doc.get_doc loc an in
      let json_fname = Json.get_json_fname s an in
      let json_tag_field = Json.get_json_tag_field an in
      { f_loc = loc;
        f_name = s;
        f_kind = fk;
        f_value = fvalue;

        f_arepr = `Field {
          Ocaml.ocaml_default = ocaml_default;
          ocaml_fname = ocaml_fname;
          ocaml_mutable = ocaml_mutable;
          ocaml_fdoc = doc;
        };

        f_brepr = `Field {
          Json.json_fname;
          json_tag_field;
          json_unwrapped;
        };
      }

  | `Inherit _ -> assert false


let def_of_atd (loc, (name, param, an), x) =
  let ocaml_predef = Ocaml.get_ocaml_predef Json an in
  let doc = Doc.get_doc loc an in
  let o =
    match as_abstract x with
        Some (_, _) ->
          (match Ocaml.get_ocaml_module_and_t Json name an with
               None -> None
             | Some (types_module, main_module, ext_name) ->
                 let args = List.map (fun s -> `Tvar (loc, s)) param in
                 Some (`External
                         (loc, name, args,
                          `External (types_module, main_module, ext_name),
                          `External))
          )
      | None -> Some (mapping_of_expr x)
  in
  {
    def_loc = loc;
    def_name = name;
    def_param = param;
    def_value = o;
    def_arepr = `Def { Ocaml.ocaml_predef = ocaml_predef;
                       ocaml_ddoc = doc };
    def_brepr = `Def;
  }

let defs_of_atd_module l =
  List.map (function `Type def -> def_of_atd def) l

let defs_of_atd_modules l =
  List.map (fun (is_rec, l) -> (is_rec, defs_of_atd_module l)) l
