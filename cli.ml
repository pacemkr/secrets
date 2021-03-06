open Core
open Secrets
open Entry

type io_format = Tsv | Sec

exception Invalid_format

let rc_path = Filename.concat (Sys.getenv_exn "HOME") ".secrets"

let rc_key_path = Filename.concat rc_path "key" 

let rc_sec_path = Filename.concat rc_path "default" 

let filename ~should_exist =
  Command.Spec.Arg_type.create (fun filename ->
      match (Sys.is_file filename, should_exist) with
      | `Yes, true | `No, false -> filename
      | `Yes, false ->
          eprintf "'%s' file already exists.\n%!" filename;
          exit 1
      | `No, true | `Unknown, _ ->
          eprintf "'%s' file not found.\n%!" filename;
          exit 1)

let with_secrets_file ~key_path ~sec_path ~f =
  let key = Crypto.create key_path in
  Crypto.with_file sec_path ~key ~f:(fun s ->
      let sec =
        match String.length s with
        | 0 -> Secrets.empty
        | _ -> Secrets.of_string s
      in
      Secrets.to_string (f sec))

let init key_path sec_path =
  Unix.mkdir_p ~perm:0o700 rc_path;
  with_secrets_file ~key_path ~sec_path ~f:Fn.id;
  if not (Sys.file_exists_exn ~follow_symlinks:false rc_sec_path) then
    Unix.symlink ~src:(Filename.realpath sec_path) ~dst:rc_sec_path

let import ~fmt =
  with_secrets_file ~f:(fun _ ->
      try
        match fmt with
        | Sec -> Secrets.of_string (In_channel.input_all In_channel.stdin)
        | Tsv ->
            let payload_keys =
              match In_channel.input_line In_channel.stdin with
              | Some l -> (
                  match String.split l ~on:'\t' with
                  | _ :: payload_keys -> payload_keys
                  | [] -> raise Invalid_format )
              | None -> raise Invalid_format
            in
            In_channel.fold_lines In_channel.stdin ~init:Secrets.empty
              ~f:(fun sec l ->
                match String.split l ~on:'\t' with
                | title :: payload_values ->
                    let payload = List.zip_exn payload_keys payload_values in
                    let entry = Entry.create title payload in
                    Secrets.add sec entry
                | [] -> raise Invalid_format)
      with Invalid_format ->
        eprintf "Invalid format.";
        exit 1)

let export =
  with_secrets_file ~f:(fun sec ->
      Out_channel.output_string stdout (Secrets.to_string sec);
      sec)

let rec edit_and_parse ?init_contents () =
  let fname = Filename.temp_file "edit" ".sec" in
  try begin
      (match init_contents with
       | Some init_contents -> (
         let oc = Out_channel.create fname in
         Out_channel.output_string oc init_contents;
         Out_channel.close oc)
       | None -> ());
      let editor =
        match Sys.getenv "EDITOR" with
        | None | Some "vim" -> "vim -n"
        | Some e -> e
      in
      ignore (Unix.system (sprintf "%s '%s'" editor fname));
      let fcontents = In_channel.read_all fname in
      try
        let sec = Secrets.of_string fcontents in
        Sys.remove fname;
        sec
      with Secrets_parser.Error ->
        let rec ask () =
          printf "Parsing error. (e)dit or (a)bort? %!";
          match Scanf.scanf "%c\n" Fn.id with
          | 'a' -> 
             (match init_contents with
              | Some c -> Secrets.of_string c
              | None -> Secrets.empty)
          | 'e' -> edit_and_parse ~init_contents:fcontents ()
          | _ -> ask ()
        in
        let res = ask () in
        Sys.remove fname;
        res
    end
  with _ ->
        Sys.remove fname;
        match init_contents with
        | Some c -> Secrets.of_string c
        | None -> Secrets.empty


let add =
  with_secrets_file ~f:(fun sec ->
      let new_entries = edit_and_parse () in
      Secrets.append sec new_entries)

let edit =
  with_secrets_file ~f:(fun sec ->
      edit_and_parse ~init_contents:(Secrets.to_string sec) ())

let rec rand_char ~alphanum =
  let c = Char.of_int_exn (33 + Random.int 94) in
  if not alphanum then c
  else match c with c when Char.is_alphanum c -> c | _ -> rand_char ~alphanum

let rand_str ~len ~alphanum =
  Random.self_init ();
  String.init len ~f:(fun _ -> rand_char ~alphanum)

let rand ?(field = "password") ?(len = 20) ~alphanum ~title =
  with_secrets_file ~f:(fun sec ->
      let rand_val = rand_str ~len ~alphanum in
      let payload = [ (field, rand_val) ] in
      let e = Entry.create title payload in
      Utils.pbcopy rand_val;
      Secrets.add sec e)

let find ~qr ~invert_colors ~query =
  with_secrets_file ~f:(fun sec ->
      Cli_find.start sec qr invert_colors query;
      sec)

let with_defaults ~f =
  let sec_path = Filename.realpath rc_sec_path in
  f ~key_path:rc_key_path ~sec_path

let io_format =
  let map = String.Map.of_alist_exn [ ("tsv", Tsv); ("sec", Sec) ] in
  Command.Spec.Arg_type.of_map map

let () =
  let open Command in
  let init_cmd =
    basic_spec ~summary:"Create a new secrets file."
      Spec.(empty +> anon ("path" %: filename ~should_exist:false))
      (fun sec_path () -> init rc_key_path sec_path)
  in
  let import_cmd =
    basic_spec ~summary:"Import secrets from stdin."
      Spec.(
        empty
        +> flag "-fmt"
             (optional_with_default Sec io_format)
             ~doc:"<tsv,sec> Input format to expect.")
      (fun fmt () -> with_defaults ~f:(import ~fmt))
  in
  let export_cmd =
    basic_spec ~summary:"Export secrets to stdin." Spec.empty (fun () ->
        with_defaults ~f:export)
  in
  let add_cmd =
    basic_spec ~summary:"Add a new secret using $EDITOR." Spec.empty (fun () ->
        with_defaults ~f:add)
  in
  let rand_cmd =
    basic_spec ~summary:"Add a new secret with a random password."
      Spec.(
        empty
        +> flag "-F"
             (optional_with_default "password" string)
             ~doc:
               "field-name Name to use for the random field. Default: password"
        +> flag "-l"
             (optional_with_default 20 int)
             ~doc:"length Length of the random value. Default: 20"
        +> flag "-s" no_arg
             ~doc:"Create a simple, alpha-numeric value. Default: false"
        +> anon ("title" %: string))
      (fun field len alphanum title () ->
        match title with
        | "" ->
            eprintf "Title cannot be empty.\n";
            exit 1
        | title -> with_defaults ~f:(rand ~field ~len ~alphanum ~title))
  in
  let edit_cmd =
    basic_spec ~summary:"Edit all secrets using $EDITOR." Spec.empty (fun () ->
        with_defaults ~f:edit)
  in
  let find_cmd =
    basic_spec ~summary:"Start fuzzy search."
      Spec.(empty
            +> flag "-qr" no_arg ~doc:"Display a QR code instead of copying to the clipboard."
            +> flag "-invert-colors" no_arg ~doc:"Invert the colors to make the QR code readable."
            +> anon (maybe ("query" %: string)))
      (fun qr invert_colors query () -> with_defaults ~f:(find ~qr ~invert_colors ~query))
  in
  run ~version:"0.1.0"
    (group ~summary:"Manage encrypted secrets."
       [
         ("init", init_cmd);
         ("add", add_cmd);
         ("rand", rand_cmd);
         ("edit", edit_cmd);
         ("find", find_cmd);
         ("import", import_cmd);
         ("export", export_cmd);
       ])
