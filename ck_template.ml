(* Copyright (C) 2015, Thomas Leonard
 * See the README file for details. *)

open Tyxml_js
open Html5
open Ck_utils

let (>|=) = Lwt.(>|=)

module Gui_tree_data = struct
  (* If the gui_data for a widget is None then it has just appeared.
   * We set the value to the newly-created element.
   *
   * If an item appears with a value already set then this is a move.
   * We read the old data to get the old height (needed for the animation),
   * and then update it to point at the new element.
   *)
  type t = Dom_html.element Js.t
end

let async ~name (fn:unit -> unit Lwt.t) =
  Lwt_js_events.async (fun () ->
    Lwt.catch fn (fun ex ->
      Printf.printf "Async error in '%s'" name;
      Lwt.fail ex
    )
  )

let close_current_model = ref None

let rec inside elem child =
  if elem == child then true
  else (
    Js.Opt.case (child##parentNode)
      (fun () -> false)
      (fun p -> inside elem p)
  )

let ignore_listener : Dom_html.event_listener_id -> unit = ignore

(* Listen to global clicks and keypresses so we can close modals on click/escape *)
let () =
  let keycode_escape = 27 in
  let click (ev:#Dom_html.mouseEvent Js.t) =
    match !close_current_model with
    | None -> Js._true
    | Some (elem, close) ->
        Js.Opt.case (ev##target)
          (fun () -> Js._true)
          (fun target ->
            if (target :> Dom.node Js.t) |> inside elem then (
              (* Click inside modal - pass it on *)
              Js._true
            ) else (
              (* Click outside modal; close the modal *)
              close_current_model := None;
              close ();
              Dom_html.stopPropagation ev;
              Js._false
            )
          ) in
  let keyup ev =
    match !close_current_model with
    | Some (_, close) when ev##keyCode = keycode_escape ->
        close_current_model := None;
        close ();
        Dom_html.stopPropagation ev;
        Js._false
    | _ -> Js._true in
  Dom_html.addEventListener Dom_html.document Dom_html.Event.click (Dom.handler click) Js._true |> ignore_listener;
  Dom_html.addEventListener Dom_html.document Dom_html.Event.keypress (Dom.handler keyup) Js._true |> ignore_listener

let current_error, set_current_error = React.S.create None

let make_error_box error =
  error
  |> React.S.map (function
    | None -> pcdata ""
    | Some err -> div ~a:[a_class ["alert-box"; "alert"; "round"]] [pcdata err]
  )
  |> ReactiveData.RList.singleton_s

let () =
  let old_hook = !Lwt.async_exception_hook in
  Lwt.async_exception_hook := (fun ex ->
    old_hook ex;
    let msg = Printexc.to_string ex in
    set_current_error (Some msg)
  )

(* Get the index of an item in an assoc list. *)
let index_of key items =
  let rec aux i = function
    | [] -> None
    | (k, _v) :: _ when k = key -> Some i
    | _ :: xs -> aux (i + 1) xs in
  aux 0 items

let auto_focus input =
  async ~name:"focus" (fun () ->
    let elem = Tyxml_js.To_dom.of_input input in
    elem##select ();
    Lwt.return ()
  )

let (>>?=) = Js.Opt.bind

module Make (M : Ck_model_s.MODEL with type gui_data = Gui_tree_data.t) = struct
  module W = M.Widget

  let current_highlight, set_highlight = React.S.create None

  let with_done cls = function
    | `Project {Ck_sigs.pstate = `Done; _}
    | `Action {Ck_sigs.astate = `Done; _} -> "ck-done" :: cls
    | _ -> cls

  let class_of_node_type = function
    | `Area -> "ck-area"
    | `Project _ -> "ck-project"
    | `Action _ -> "ck-action"
    | `Deleted -> "ck-deleted"

  let class_of_time_and_type ctime node_type =
    let ty = with_done ["ck-item"; class_of_node_type node_type] node_type in
    let lifetime = Unix.gettimeofday () -. ctime in
    if lifetime >= 0.0 && lifetime <  1.0 then "new" :: ty
    else ty

  let toggle_label ~set_details ~current details =
    let l =
      match details with
      | `Done -> "✓"
      | `Next -> "n"
      | `Waiting -> "w"
      | `Future -> "f"
      | `Active -> "a"
      | `SomedayMaybe -> "sm" in
    let cl = if current = details then "ck-active-" ^ l else "ck-inactive" in
    let changed _ev =
      if current <> details then set_details details; true in
    a ~a:[a_class [cl]; a_onclick changed] [pcdata l]

  let make_toggles ~m ~set_details ~item current options =
    let starred = M.Item.starred item in
    let state_toggles = options |> List.map (toggle_label ~set_details ~current) in
    let cl = if starred then "star-active" else "star-inactive" in
    let set_star _ev =
      async ~name:"set_starred" (fun () -> M.set_starred m item (not starred));
      true in
    let star = a ~a:[a_class [cl]; a_onclick set_star] [pcdata "★"] in
    state_toggles @ [star]

  let toggles_for_type m item =
    match M.Item.ty item with
    | `Action item ->
        let set_details n =
          async ~name:"set_action_state" (fun () -> M.set_action_state m item n) in
        make_toggles ~m ~set_details ~item (M.Item.action_state item) [`Done; `Next; `Waiting; `Future]
    | `Project item ->
        let set_details n =
          async ~name:"set_project_state" (fun () -> M.set_project_state m item n) in
        make_toggles ~m ~set_details ~item (M.Item.project_state item) [`Done; `Active; `SomedayMaybe]
    | `Area _ -> []

  let make_state_toggles m item =
    let toggles = item >|~= (function
      | Some item -> toggles_for_type m item
      | None -> []
    ) in
    rlist_of ~init:(React.S.value toggles) toggles

  (* Fade item in and out based on state. *)
  let animated widget child_nodes =
    let li_state =
      W.state widget >|~= fun state ->
        let gui_data = W.gui_data widget in
        let old_item = !gui_data in   (* The original that is being moved, if any *)
        match state, old_item with
        | `Removed _time, _ -> `Fade_out
        | (`New | `Init), Some old_item -> `Fade_in_from old_item
        | `Current, _ -> `No_animation
        | `Init, None -> `No_animation
        | `New, None -> `Fade_in
        in
    let li_cl = li_state |> React.S.map (function
        | `Fade_in -> ["new"]
        | `Fade_out -> ["removed"]
        | `Fade_in_from _ -> ["moved"]
        | `No_animation -> []
    ) in
    let li_elem = li ~a:[R.Html5.a_class li_cl] child_nodes in
    let cancel = ref ignore in
    let animate =
      li_state >|~= fun animation ->
        !cancel ();
        cancel := ignore;
        let gui_data = W.gui_data widget in
        (* Update to point at the new element *)
        gui_data := Some (Tyxml_js.To_dom.of_li li_elem);
        match animation with
        | `Fade_out ->
            let elem = Tyxml_js.To_dom.of_element li_elem in
            cancel := Ck_animate.fade_out elem;
        | `Fade_in_from old_item ->
            let full_height = old_item##offsetHeight in
            cancel := Ck_animate.fade_in_move ~full_height li_elem
        | `Fade_in -> ()    (* Handled by the CSS alone *)
        | `No_animation -> () in
    React.S.retain li_state (fun () -> ignore animate) |> ignore;
    li_elem

  let render_item m ~show_node item =
    let clicked _ev = show_node item; true in
    let delete _ev = async ~name:"delete" (fun () -> M.delete m item); true in
    let details = M.Item.details item in
    let item_cl = class_of_time_and_type (M.Item.ctime item) details in
    span ~a:[a_class item_cl] [
      span ~a:[a_class ["ck-toggles"]] (toggles_for_type m item);
      span ~a:[a_class ["allow-strikethrough"]] [   (* CSS hack to allow strikethrough and underline together *)
        a ~a:[a_class ["ck-title"]; a_href "#"; a_onclick clicked] [pcdata (M.Item.name item)];
      ];
      a ~a:[a_class ["delete"]; a_onclick delete] [entity "cross"];
    ]

  let group_label s =
    span ~a:[a_class ["ck-group-label"]] [pcdata s]

  (* A <li>[toggles] name x [children]</li> element *)
  let rec make_tree_node_view m ~show_node widget : _ Html5.elt =
    let item = W.item widget in
    let children = W.children widget
      |> ReactiveData.RList.map (make_tree_node_view m ~show_node) in
    let item_html =
      match item with
      | `Item item ->
          ReactiveData.RList.singleton_s item
          |> ReactiveData.RList.map (render_item m ~show_node)
          |> R.Html5.span
      | `Group label -> group_label label in
    animated widget [
      item_html;
      R.Html5.ul children;
    ]

  let make_work_view m ~show_node groups =
    let make_work_actions group =
      let item_html =
        match W.item group with
        | `Item item ->
            let show_group _ev =
              React.S.value item |> show_node;
              true in
            let name = item >|~= M.Item.name in
            a ~a:[a_class ["ck-group"]; a_onclick show_group] [R.Html5.pcdata name];
        | `Group label -> group_label label in
      animated group [
        item_html;
        R.Html5.ul (
          ReactiveData.RList.map (make_tree_node_view m ~show_node) (W.children group)
        )
      ] in
    let children = groups |> ReactiveData.RList.map make_work_actions in
    [
      h4 [pcdata "Next actions"];
      R.Html5.ul children;
    ]

  let make_sync history =
    let items =
      rlist_of ~init:(React.S.value history) history
      |> ReactiveData.RList.map (fun (date, summary) ->
          let open Unix in
          let tm = gmtime date in
          let msg = Printf.sprintf "%04d-%02d-%02d: %s"
            (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
            summary in
          li [pcdata msg]
      ) in
    [
      h4 [pcdata "Recent changes"];
      R.Html5.ol ~a:[a_class ["ck-history"]] items;
    ]

  let make_tree ~show_node m = function
    | `Process process_tree ->
        [R.Html5.ul (
          ReactiveData.RList.map (make_tree_node_view m ~show_node) process_tree
        )]
    | `Work work_tree -> make_work_view m ~show_node work_tree
    | `Sync history -> make_sync history
    | `Contact () | `Review () | `Schedule () -> [p [pcdata "Not implemented yet"]]

  let mode_of = function
    | `Process _ -> `Process
    | `Work _ -> `Work
    | `Review _ -> `Review
    | `Contact _ -> `Contact
    | `Schedule _ -> `Schedule
    | `Sync _ -> `Sync

  let make_mode_switcher m current_tree =
    let item name mode =
      let cl = current_tree |> React.S.map (fun t ->
        if (mode_of t) = mode then ["active"] else []
      ) in
      let clicked _ev = M.set_mode m mode; true in
      let button = a ~a:[a_href "#"; a_onclick clicked] [pcdata name] in
      dd ~a:[R.Html5.a_class cl] [button] in

    dl ~a:[a_class ["sub-nav"]] [
      item "Process" `Process;
      item "Work" `Work;
      item "Review" `Review;
      item "Contact" `Contact;
      item "Schedule" `Schedule;
      item "Sync" `Sync;
    ]

  let assume_changed _ _ = false

  let add_form ~close ~show_node ?parent adder =
    let do_add ev =
      let form = ev##target >>?= Dom_html.CoerceTo.form in
      Js.Opt.iter form (fun form ->
        let f = Form.get_form_contents form in
        let name = List.assoc "name" f |> String.trim in
        if name <> "" then (
          async ~name:"add" (fun () ->
            adder ?parent ~name ~description:"" >|= function
            | None -> print_endline "Added item no longer exists!"
            | Some item -> show_node item
          )
        );
        close ()
      );
      true in
    let name_input = input ~a:[a_name "name"; a_placeholder "Name"] () in
    auto_focus name_input;
    form ~a:[a_onsubmit do_add] [
      name_input;
      input ~a:[a_input_type `Submit; a_value "Add"] ();
      a ~a:[a_onclick (fun _ev -> close (); true)] [pcdata " (cancel)"];
    ]

  let make_child_adder m ~show_node item =
    let editing, set_editing = React.S.create ~eq:assume_changed None in
    let add_button adder label =
      let start_editing (_:#Dom_html.event Js.t) =
        match React.S.value item with
        | None -> true    (* Item is deleted; ignore *)
        | Some item ->
            set_editing (Some (item, adder));
            true in
      li [a ~a:[a_onclick start_editing] [pcdata label]] in
    let widgets =
      editing >>~= (function
        (* When we're not editing, display the add buttons. *)
        | None ->
            item >|~= (function
              | None -> pcdata ""
              | Some item ->
                  match M.Item.details item with
                  | `Action _ -> pcdata ""
                  | `Project _ -> ul ~a:[a_class ["add"]] [
                      add_button (M.add_project m) "+sub-project";
                      add_button (M.add_action m) "+action";
                    ]
                  | `Area -> ul ~a:[a_class ["add"]] [
                      add_button (M.add_area m) "+sub-area";
                      add_button (M.add_project m) "+project";
                      add_button (M.add_action m) "+action";
                    ]
            )
        (* When we are editing, display the form. *)
        | Some (item, adder) ->
            let close () = set_editing None in
            React.S.const (add_form ~close ~show_node ~parent:item adder)
      )
    in
    let rlist = ReactiveData.RList.singleton_s widgets in
    R.Html5.div ~a:[a_class ["add"]] rlist

  let make_editable_title m item =
    let name = item >|~= (function
      | Some item -> M.Item.name item
      | None -> "(deleted)"
    ) in
    let editing, set_editing = React.S.create None in
    let widgets =
      editing >|~= (function
        | None ->
            let edit _ev =
              begin match React.S.value item with
              | None -> ()
              | Some item -> set_editing (Some item) end;
              true in
            [
              span ~a:[a_class ["allow-strikethrough"]] [   (* CSS hack to allow strikethrough and underline together *)
                a ~a:[a_class ["ck-title"]; a_onclick edit] [R.Html5.pcdata name];
              ]
            ]
        | Some item ->
            let submit ev =
              let form = ev##target >>?= Dom_html.CoerceTo.form in
              Js.Opt.iter form (fun form ->
                let f = Form.get_form_contents form in
                let name = List.assoc "name" f |> String.trim in
                if name <> "" then (
                  async ~name:"set_name" (fun () -> M.set_name m item name)
                )
              );
              set_editing None;
              true in
            let old_name = React.S.value name in
            let name_input = input ~a:[a_name "name"; a_placeholder "Name"; a_size 25; a_value old_name] () in
            auto_focus name_input;
            [
              form ~a:[a_class ["rename"]; a_onsubmit submit] [
                name_input;
                input ~a:[a_input_type `Submit; a_value "OK"] ();
              ]
            ]
      ) in
    rlist_of ~init:(React.S.value widgets) widgets

  let parent_candidates m ~close_menu item =
    match React.S.value item with
    | None -> []
    | Some item ->
    M.candidate_parents_for m item |> List.map (fun candidate ->
      let clicked _ev =
        close_menu ();
        async ~name:"set parent" (fun () -> M.set_parent candidate);
        true in
      li [
        a ~a:[a_onclick clicked] [
          pcdata (M.candidate_label candidate)
        ]
      ]
    )

  let make_parent_details m ~show_node details =
    let dropdown, set_dropdown = React.S.create [] in
    let dropdown_style, set_dropdown_style = React.S.create "" in
    let descr =
      details.M.details_item >|~= function
        | None -> "(deleted)"
        | Some item ->
            match M.Item.ty item with
            | `Action _ -> "An action in "
            | `Project _ -> "A project in "
            | `Area _ -> "An area in " in
    let title =
      details.M.details_parent >|~= function
        | None -> pcdata "(no parent)"
        | Some parent ->
            let cl = ["ck-item"; class_of_node_type (M.Item.details parent)] in
            let clicked _ev = show_node parent; true in
            span ~a:[a_class cl] [
              a ~a:[a_class ["ck-title"]; a_onclick clicked] [pcdata (M.Item.name parent)]
            ] in
    let title_elem = R.Html5.span (ReactiveData.RList.singleton_s title) in
    let close_menu () =
      set_dropdown [];
      set_dropdown_style "";
      close_current_model := None in
    let dropdown_menu =
      R.Html5.ul ~a:[a_class ["ck-dropdown"; "f-dropdown"]; R.Html5.a_style dropdown_style] (
        rlist_of ~init:[] dropdown;
      ) in
    let change_clicked _ev =
      if React.S.value dropdown_style = "" then (
        let elem = Tyxml_js.To_dom.of_span title_elem in
        let left = elem##offsetLeft in
        let top = elem##offsetTop + elem##offsetHeight in
        set_dropdown (parent_candidates m ~close_menu details.M.details_item);
        set_dropdown_style (Printf.sprintf "position: absolute; left: %dpx; top: %dpx;" left top);
        close_current_model := Some (Tyxml_js.To_dom.of_node dropdown_menu, close_menu)
      ) else close_menu ();
      true in
    div [
      dropdown_menu;
      span ~a:[a_class ["ck-label"]] [R.Html5.pcdata descr];
      title_elem;
      a ~a:[a_onclick change_clicked] [pcdata " (change)"];
    ]

  let make_details_panel m ~show_node ~remove ~uuid details =
    let closed, set_closed = React.S.create false in
    let close () =
      set_closed true;                          (* Start fade-out animation *)
      details.M.details_stop ();
    in
    let elem = ref None in
    let cl =
      let cancel_close = ref ignore in
      closed >>~= (fun closed ->
        !cancel_close ();
        begin match closed, !elem with
        | true, Some elem ->
            let elem = Tyxml_js.To_dom.of_element elem in
            let cancel_anim = Ck_animate.fade_out elem in
            let delete_panel = Lwt_js.sleep 0.5 >|= remove in
            cancel_close := (fun () ->
              Lwt.cancel delete_panel;
              cancel_anim ()
            )
        | _ -> () end;
        current_highlight |> React.S.map (fun highlight ->
          "ck-details" :: List.concat [
            if highlight = Some uuid then ["ck-highlight"] else [];
            if closed then ["closed"] else [];
          ]
        )
      ) in
    let item = details.M.details_item in
    let title_cl =
      item >|~= (function
        | None ->
            set_closed true;
            ["ck-heading"]
        | Some item ->
            let node_type = M.Item.details item in
            with_done ["ck-heading"; class_of_node_type node_type] node_type
      ) in
    let children = details.M.details_children
      |> ReactiveData.RList.map (make_tree_node_view m ~show_node) in
    let result =
      div ~a:[R.Html5.a_class cl] [
        a ~a:[a_onclick (fun _ -> close (); true); a_class ["close"]] [entity "#215"];
        div ~a:[R.Html5.a_class title_cl] [
          R.Html5.span ~a:[a_class ["ck-toggles"]] (make_state_toggles m item);
          R.Html5.div ~a:[a_class ["inline"]] (make_editable_title m item);
        ];
        make_parent_details m ~show_node details;
        R.Html5.ul ~a:[a_class ["ck-groups"]] children;
        make_child_adder m ~show_node item;
        div ~a:[a_class ["description"]] [
          p [R.Html5.pcdata (item >|~= function
            | Some item -> M.Item.description item
            | None -> "This item has been deleted."
          )];
        ]
      ] in
    elem := Some result;
    result

  let make_toplevel_adders m ~show_node =
    let editing, set_editing = React.S.create ~eq:assume_changed None in
    let make adder label =
      let clicked _ev =
        set_editing (Some adder);
        true in
      li [a ~a:[a_onclick clicked] [pcdata label]] in
    let widget =
      editing >|~= function
      | None ->
          ul ~a:[a_class ["ck-adders"]] [
            make (M.add_area m) "+area";
            make (M.add_project m) "+project";
            make (M.add_action m) "+action";
          ]
      | Some adder ->
          let close () = set_editing None in
          add_form ~close ~show_node adder in
    ReactiveData.RList.singleton_s widget

  let make_details_area m =
    let details_pane, details_handle = ReactiveData.RList.make [] in
    let rec show_node item =
      let uuid = M.Item.uuid item in
      let remove () =
        let current_items = ReactiveData.RList.value details_pane in
        match index_of uuid current_items with
        | None -> ()
        | Some i-> ReactiveData.RList.remove i details_handle in
      let current_items = ReactiveData.RList.value details_pane in
      let existing =
        try
          Some (List.find (fun (id, _) -> id = uuid) current_items)
        with Not_found -> None in
      match existing with
      | None ->
          let details = M.details m item in
          ReactiveData.RList.insert (uuid, make_details_panel m ~show_node ~remove ~uuid details) (List.length current_items) details_handle;
      | Some _ ->
          set_highlight (Some uuid);
          async ~name:"highlight" (fun () ->
            Lwt_js.sleep 1.0 >|= fun () ->
            if React.S.value current_highlight = Some uuid then set_highlight None
          )
      in
    (ReactiveData.RList.map snd details_pane, show_node)

  let make_top m =
    let current_tree = M.tree m in
    let details_area, show_node = make_details_area m in
    let left_panel =
      let live = current_tree >|~= make_tree ~show_node m in
      rlist_of ~init:(React.S.value live) live in
    [
      div ~a:[a_class ["row"]] [
        div ~a:[a_class ["large-8"; "columns"; "ck-tree"]] [
          make_mode_switcher m current_tree;
        ];
        R.Html5.div ~a:[a_class ["large-4"; "columns"; "ck-tree"; "add"]] (
          make_toplevel_adders m ~show_node
        );
      ];
      div ~a:[a_class ["row"]] [
        R.Html5.div ~a:[a_class ["medium-12"; "columns"; "ck-tree"]] (
          make_error_box current_error;
        )
      ];
      div ~a:[a_class ["row"]] [
        R.Html5.div ~a:[a_class ["medium-6"; "columns"; "ck-tree"]] (
          left_panel;
        );
        R.Html5.div ~a:[a_class ["medium-6"; "columns"]] (
          details_area;
        );
      ]
    ]
end
