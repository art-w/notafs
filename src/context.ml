module type SIMPLE_DISK = sig
  type error
  type write_error
  type t

  val pp_error : Format.formatter -> error -> unit
  val pp_write_error : Format.formatter -> write_error -> unit
  val get_info : t -> Mirage_block.info Lwt.t
  val read : t -> int64 -> Cstruct.t list -> (unit, error) result Lwt.t
  val write : t -> int64 -> Cstruct.t list -> (unit, write_error) result Lwt.t
end

module type A_DISK = sig
  module Id : Id.S
  module Check : Checksum.S
  module Diet : module type of Diet.Make (Id)

  type read_error
  type write_error

  type error =
    [ `Read of read_error
    | `Write of write_error
    | `Invalid_checksum of Int64.t
    | `All_generations_corrupted
    | `Disk_not_formatted
    | `Disk_is_full
    | `Wrong_page_size of int
    | `Wrong_disk_size of Int64.t
    | `Wrong_checksum_algorithm of string * int
    ]

  val pp_error : Format.formatter -> error -> unit
  val page_size : int
  val header_size : int
  val nb_sectors : int64

  type sector

  val set_id : sector Lru.elt -> Id.t -> unit
  val lru : sector Lru.t
  val protect_lru : (unit -> 'a Lwt.t) -> 'a Lwt.t
  val cstruct : sector Lru.elt -> (Cstruct.t, [> `Read of read_error ]) Lwt_result.t
  val cstruct_in_memory : sector Lru.elt -> Cstruct.t
  val read : Id.t -> Cstruct.t -> (unit, [> `Read of read_error ]) Lwt_result.t
  val write : Id.t -> Cstruct.t list -> (unit, [> `Write of write_error ]) Lwt_result.t
  val discard : Id.t -> unit
  val discard_range : Id.t * int -> unit
  val acquire_discarded : unit -> (Id.t * int) list
  val allocator : (int -> ((Id.t * int) list, error) Lwt_result.t) ref
  val allocate : from:[ `Root | `Load ] -> unit -> (sector Lru.elt, error) Lwt_result.t
  val unallocate : sector Lru.elt -> unit
  val clear : unit -> (unit, error) Lwt_result.t

  val set_finalize
    :  sector
    -> (unit
        -> ((int * (Id.t -> (unit, error) Lwt_result.t), Id.t) result, error) Lwt_result.t)
    -> unit
end

let of_impl
  (type t e we)
  (module B : SIMPLE_DISK with type t = t and type error = e and type write_error = we)
  (module Check : Checksum.S)
  (disk : t)
  =
  let open Lwt.Syntax in
  let+ info = B.get_info disk in
  (module struct
    module Id = (val Id.of_nb_pages info.size_sectors)
    module Check = Check
    module Diet = Diet.Make (Id)

    type page =
      | Cstruct of Cstruct.t
      | On_disk of Id.t
      | Freed

    type read_error = B.error
    type write_error = B.write_error

    type error =
      [ `Read of read_error
      | `Write of write_error
      | `Invalid_checksum of Int64.t
      | `All_generations_corrupted
      | `Disk_is_full
      | `Disk_not_formatted
      | `Wrong_page_size of int
      | `Wrong_disk_size of Int64.t
      | `Wrong_checksum_algorithm of string * int
      ]

    let pp_error h = function
      | `Read e -> B.pp_error h e
      | `Write e -> B.pp_write_error h e
      | `Invalid_checksum id ->
        Format.fprintf h "Invalid_checksum %s" (Int64.to_string id)
      | `All_generations_corrupted -> Format.fprintf h "All_generations_corrupted"
      | `Disk_not_formatted -> Format.fprintf h "Disk_not_formatted"
      | `Disk_is_full -> Format.fprintf h "Disk_is_full"
      | `Wrong_page_size s -> Format.fprintf h "Wrong_page_size %d" s
      | `Wrong_disk_size i -> Format.fprintf h "Wrong_disk_size %s" (Int64.to_string i)
      | `Wrong_checksum_algorithm (s, i) ->
        Format.fprintf h "Wrong_checksum_algorithm (%s, %d)" s i
      | `Unsupported_operation msg -> Format.fprintf h "Unsupported_operation %S" msg
      | `Disk_failed -> Format.fprintf h "Disk_failed"

    type sector =
      { mutable cstruct : page
      ; mutable finalize :
          unit
          -> ( (int * (Id.t -> (unit, error) Lwt_result.t), Id.t) result
             , error )
             Lwt_result.t
      }

    let header_size = 1
    let page_size = info.sector_size
    let nb_sectors = info.size_sectors

    let read page_id cstruct =
      let page_id = Id.to_int64 page_id in
      let open Lwt.Syntax in
      let+ r = B.read disk page_id [ cstruct ] in
      Result.map_error (fun e -> `Read e) r

    let write page_id cstructs =
      let page_id = Id.to_int64 page_id in
      let open Lwt.Syntax in
      let+ result = B.write disk page_id cstructs in
      Result.map_error (fun e -> `Write e) result

    let discarded = ref Diet.empty
    let discard page_id = discarded := Diet.add !discarded page_id
    let discard_range r = discarded := Diet.add_range !discarded r

    let acquire_discarded () =
      let lst = Diet.to_range_list !discarded in
      discarded := Diet.empty ;
      lst

    let allocator = ref (fun _ -> failwith "no allocator")
    let lru = Lru.make ()
    let safe_lru = ref true

    let protect_lru fn =
      assert !safe_lru ;
      safe_lru := false ;
      Lwt.map
        (fun v ->
          safe_lru := true ;
          v)
        (fn ())

    let max_lru_size = 1024
    let min_lru_size = max_lru_size / 2
    let available_cstructs = ref []
    let nb_available = ref 0

    let release_cstructs cstructs =
      if !nb_available < max_lru_size
      then begin
        nb_available := !nb_available + List.length cstructs ;
        available_cstructs := List.rev_append cstructs !available_cstructs
      end

    let unallocate elt =
      let t = Lru.value elt in
      begin
        match t.cstruct with
        | Cstruct cstruct ->
          release_cstructs [ cstruct ] ;
          t.cstruct <- Freed
        | On_disk _id -> ()
        | Freed -> failwith "Context.unallocate Freed"
      end ;
      Lru.detach elt lru

    let set_id elt id =
      let t = Lru.value elt in
      begin
        match t.cstruct with
        | Cstruct cstruct ->
          release_cstructs [ cstruct ] ;
          t.cstruct <- On_disk id
        | On_disk id' -> assert (Id.equal id id')
        | Freed -> failwith "Context.set_id: Freed"
      end ;
      Lru.detach_remove elt lru

    let rec write_all = function
      | [] -> Lwt_result.return ()
      | (id, cs) :: css ->
        let open Lwt_result.Syntax in
        let id_ = Int64.to_int @@ Id.to_int64 id in
        assert (id_ <> 0 && id_ <> 1) ;
        let* () = write id cs in
        write_all css

    let no_finalizer _ = failwith "no finalizer"

    let rec list_align_with acc rest n ss =
      match rest, ss with
      | ((_, len) as r) :: rest, _ when len = n -> list_align_with (r :: acc) rest 0 ss
      | _, _ :: ss -> list_align_with acc rest (succ n) ss
      | [], [] -> acc, rest
      | _, [] when n = 0 -> acc, rest
      | (id, len) :: rest, [] -> (id, n) :: acc, (Id.add id n, len - n) :: rest

    let rec lru_clear () =
      let open Lwt_result.Syntax in
      match Lru.pop_back lru with
      | None -> Lwt_result.return ()
      | Some old ->
        let* () =
          match old.cstruct with
          | Freed -> failwith "Cstruct.lru_make_room: Freed"
          | On_disk _ -> Lwt_result.return ()
          | Cstruct _cstruct -> begin
            let* fin = old.finalize () in
            match fin with
            | Error page_id ->
              release_cstructs [ _cstruct ] ;
              old.cstruct <- On_disk page_id ;
              Lwt_result.return ()
            | Ok _ -> Lwt_result.return ()
          end
        in
        lru_clear ()

    let clear () =
      let open Lwt_result.Syntax in
      let+ () = lru_clear () in
      available_cstructs := [] ;
      nb_available := 0

    let rec lru_make_room acc =
      let open Lwt_result.Syntax in
      if (Lru.length lru < min_lru_size && !available_cstructs <> [])
         ||
         match Lru.peek_back lru with
         | None -> true
         | Some e when e.finalize == no_finalizer -> true
         | _ -> false
      then begin
        match acc with
        | [] -> Lwt_result.return ()
        | _ -> begin
          let nb = List.length acc in
          let* ids = !allocator nb in
          let acc =
            List.filter
              (fun (s, _, _) ->
                match s.cstruct with
                | Cstruct _ -> true
                | _ -> false)
              acc
          in
          let ids, ids_rest = list_align_with [] ids 0 acc in
          List.iter discard_range ids_rest ;
          let acc =
            List.sort
              (fun (_, a_depth, _) (_, b_depth, _) -> Int.compare b_depth a_depth)
              acc
          in
          let rec finalize acc css ids n ss =
            match ids, ss with
            | [], [] -> Lwt_result.return acc
            | (id, len) :: ids, _ when n = len ->
              finalize ((id, List.rev css) :: acc) [] ids 0 ss
            | (id, _) :: _, (s, _, finalizer) :: ss ->
              let* cstruct =
                match s.cstruct with
                | Cstruct cstruct ->
                  let id = Id.add id n in
                  let+ () = finalizer id in
                  s.cstruct <- On_disk id ;
                  cstruct
                | On_disk _ -> assert false
                | Freed -> assert false
              in
              finalize acc (cstruct :: css) ids (succ n) ss
            | _, [] | [], _ -> assert false
          in
          let* cstructs = finalize [] [] ids 0 acc in
          let+ () = write_all cstructs in
          let rec sanity_check ids n ss =
            match ids, ss with
            | [], [] -> ()
            | (_, len) :: ids, _ when n = len -> sanity_check ids 0 ss
            | (id, _) :: _, (s, _, _) :: ss ->
              begin
                match s.cstruct with
                | On_disk id' -> assert (Id.add id n = id')
                | Cstruct _ -> failwith "Context.sanity_check: Cstruct"
                | Freed -> failwith "Context.sanity_check: Freed"
              end ;
              sanity_check ids (succ n) ss
            | _, [] | [], _ -> assert false
          in
          sanity_check ids 0 acc ;
          List.iter release_cstructs (List.map snd cstructs)
        end
      end
      else
        let* acc =
          match Lru.pop_back lru with
          | None -> assert false
          | Some old -> begin
            match old.cstruct with
            | Freed -> failwith "Cstruct.lru_make_room: Freed"
            | On_disk _ -> Lwt_result.return acc
            | Cstruct _cstruct -> begin
              let* fin = old.finalize () in
              match fin with
              | Error page_id ->
                release_cstructs [ _cstruct ] ;
                old.cstruct <- On_disk page_id ;
                (*
                   let fake_cstruct = Cstruct.create page_size in
                   let* () = read page_id fake_cstruct in
                   if not (Cstruct.to_string cstruct = Cstruct.to_string fake_cstruct)
                   then begin
                   Format.printf "===== SECTOR %s =====@." (Id.to_string page_id) ;
                   Format.printf "EXPECTED %S@." (Cstruct.to_string cstruct) ;
                   Format.printf "     GOT %S@." (Cstruct.to_string fake_cstruct) ;
                   failwith "inconsistent"
                   end ;
                *)
                Lwt_result.return acc
              | Ok (depth, finalizer) -> Lwt_result.return ((old, depth, finalizer) :: acc)
            end
          end
        in
        lru_make_room acc

    let cstruct_create () =
      match !available_cstructs with
      | [] ->
        assert (!nb_available = 0) ;
        Cstruct.create page_size
      | c :: css ->
        decr nb_available ;
        available_cstructs := css ;
        c

    let allocate ~from () =
      let sector () =
        { cstruct = Cstruct (cstruct_create ()); finalize = no_finalizer }
      in
      match from with
      | `Root -> Lwt_result.return (Lru.make_detached (sector ()))
      | `Load -> begin
        let open Lwt_result.Syntax in
        let make_room () =
          if (not !safe_lru) || Lru.length lru < max_lru_size
          then Lwt_result.return ()
          else protect_lru (fun () -> lru_make_room [])
        in
        let+ () = make_room () in
        Lru.make_elt (sector ()) lru
      end

    let set_finalize s fn = s.finalize <- fn

    let cstruct_in_memory elt =
      let sector = Lru.value elt in
      match sector.cstruct with
      | Cstruct cstruct -> cstruct
      | On_disk _ -> failwith "Context.cstruct_in_memory: On_disk"
      | Freed -> failwith "Context.cstruct_in_memory: Freed"

    let cstruct elt =
      Lru.use elt lru ;
      let sector = Lru.value elt in
      match sector.cstruct with
      | Freed -> failwith "Context.cstruct: Freed"
      | Cstruct cstruct -> Lwt_result.return cstruct
      | On_disk page_id ->
        let cstruct = cstruct_create () in
        let open Lwt_result.Syntax in
        let+ () = read page_id cstruct in
        sector.cstruct <- Cstruct cstruct ;
        cstruct
  end : A_DISK
    with type read_error = e
     and type write_error = we)
