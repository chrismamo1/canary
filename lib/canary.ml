let ( let* ) = Lwt_result.bind

type 'a notifier = additional:string -> exn -> string -> ('a, string) Lwt_result.t

module Notifier = struct
  module type Notifier_s = sig
    type notifier_rv
    val notify : notifier_rv notifier
  end

  module type GitlabConf = sig
    val token : string
    val uri_base : string
    val project_name : string
    val project_id : int
  end

  module Gitlab(Conf : GitlabConf) : Notifier_s with type notifier_rv := int = struct
    type gitlab_issue_api_repr =
      { description: string option
      ; id: int
      ; title: string
      ; iid: int
      ; project_id: int
      }
      [@@deriving yojson {strict = false}]

    let make_api_call
      ~(meth :
          ?ctx:Cohttp_lwt_unix.Net.ctx ->
          ?headers:Cohttp.Header.t ->
          Uri.t -> (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t)
      ~resource
      ?(get_params = [])
      ?(headers = [])
      ()
    =
      let headers =
        Cohttp.Header.of_list (
          List.append
            headers
            [ "content-type", "application/x-www-form-urlencoded"
            ; "PRIVATE_TOKEN", Conf.token
            ]
        )
      in
      let uri =
        let uri = Uri.of_string (Conf.uri_base ^ resource) in
        Uri.add_query_params uri get_params
      in
      let%lwt (resp, body) = meth ~headers uri in
      match resp.Cohttp_lwt.Response.status with
      | x when Cohttp.Code.is_success(Cohttp.Code.code_of_status x) ->
        let%lwt body' = Cohttp_lwt.Body.to_string body in
        Lwt.return_ok(body')
      | _ ->
        let%lwt msg = Cohttp_lwt.Body.to_string body in
        Lwt.return_error("Request failed: " ^ msg)
    let make_post_call ~post_params =
      let post_body =
        let params =
          List.map
            (fun (key, value) ->
              let enc = Uri.pct_encode ~component:`Generic in
              enc key ^ "=" ^ enc value)
            post_params
        in
        String.concat ";" params
      in
      let meth =
        Cohttp_lwt_unix.Client.post
          ~chunked:false
          ~body:(Cohttp_lwt.Body.of_string post_body)
      in
      make_api_call ~meth
    let make_get_call ~get_params =
      let meth = Cohttp_lwt_unix.Client.get in
      make_api_call ~meth ~get_params
    let get_gitlab_issues ?title ?iids ?description () =
      let get_params =
        let search_in, search =
          match title, description with
          | Some title, None ->
            Some ["title"], Some [title]
          | None, Some description ->
            Some ["description"], Some [description]
          | Some title, Some description ->
            Some ["title"; "description"], Some[title ^ " " ^ description]
          | None, None ->
            None, None
        in
        [ Option.map (fun iids -> "iids[]", iids) iids
        ; Option.map (fun search -> "search", search) search
        ; Option.map (fun search_in -> "search_in", search_in) search_in
        ]
        |> List.filter Option.is_some
        |> List.map Option.get
      in
      let* resp = make_get_call ~resource:"/issues" ~get_params () in
      let resp' = Yojson.Safe.from_string resp in
      let* rv =
        match resp' with
        | `List ls ->
          List.map
            gitlab_issue_api_repr_of_yojson
            ls
          |> List.fold_left
              (fun acc x ->
                match acc, x with
                | Ok acc', Ok x -> Ok(x :: acc')
                | Error _, _ -> acc
                | Ok _, Error x' -> Error x')
              (Ok[])
          |> Lwt.return
        | _ ->
          Lwt.return_error "Retrieved value is not a list"
      in
      Lwt.return_ok rv

    let create_gitlab_issue ~description title =
      let* resp =
        let resource =
          Printf.sprintf "/projects/%d/issues" Conf.project_id
        in
        make_post_call
          ~post_params:["description", description]
          ~get_params:["title", [title]]
          ~resource
          ()
      in
      let resp' = Yojson.Safe.from_string resp in
      begin match Yojson.Safe.Util.member "iid" resp' with
      | `Int x -> Lwt.return_ok x
      | _ -> Lwt.return_error "Invalid issue ID"
      end
    let comment_on_issue ~iid body =
      let resource =
        Printf.sprintf
          "/projects/%d/issues/%d/notes"
          Conf.project_id
          iid
      in
      let* _resp = make_post_call ~post_params:["body", body] ~resource () in
      Lwt.return_ok()

    (** [notify ~additional exn trace] notify an unhandled exception to GitLab.
    
    This reporter generates a digest of the exception message and trace. The
    issue will be titled as
    [textual representation of exception | first 10 characters of digest]. Each
    time the notifier is called, it searches GitLab for an exception whose title
    contains the first ten characters of the aforementioned digest. Each time
    the exception is caught, the notifier will comment with the [additional]
    information passed. *)
    let notify ~additional exn trace =
      let trace_md5 = String.sub Digest.(to_hex (string trace)) 0 10 in
      let description = Printf.sprintf "```\n%s\n```" trace in
      let exn = Printexc.to_string exn in
      let* existing = get_gitlab_issues ~title:(trace_md5) () in
      let title = exn ^ " | " ^ trace_md5 in
      let* iid =
        match existing with
        | [issue] ->
          Lwt.return_ok issue.iid
        | [] ->
          create_gitlab_issue ~description title
        | _ ->
          Lwt.return_error "Multiple gitlab issues match this exception/description set."
      in
      let* () = comment_on_issue ~iid additional in
      Lwt.return_ok iid
  end
end

(** [handle ~notify f] executes the function [f], catching any exceptions and
    passing those exceptions to [notify.] *)
let handle ~notify (f: unit -> 'a Lwt.t) =
  Lwt.catch
    f
    (fun exn ->
      match%lwt notify (Printexc.to_string exn) (Printexc.get_backtrace ()) with
      | Ok _ -> Lwt.return()
      | Error err -> Lwt_io.printlf "Error notifying exception: %s" err)
