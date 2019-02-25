(* This file is part of Luv, released under the MIT license. See LICENSE.md for
   details, or visit https://github.com/aantron/luv/blob/master/LICENSE.md. *)



open Test_helpers

let with_udp f =
  let udp = Luv.UDP.init () |> check_success_result "init" in

  f udp;

  Luv.Handle.close udp;
  run ()

let with_sender_and_receiver ~receiver_logic ~sender_logic =
  let address = fresh_address () in

  let receiver = Luv.UDP.init () |> check_success_result "receiver init" in
  Luv.UDP.bind receiver address |> check_success "bind";

  let sender = Luv.UDP.init () |> check_success_result "sender init" in

  receiver_logic receiver;
  sender_logic sender address;

  run ()

let expect ?(buffer_not_used = false) receiver expected_data k =
  let buffer_not_used_callback =
    if buffer_not_used then
      k
    else
      fun () -> Alcotest.fail "received no data"
  in

  Luv.UDP.recv_start
      ~buffer_not_used:buffer_not_used_callback receiver begin fun result ->

    let buffer, _peer_address, truncated =
      check_success_result "recv_start" result in
    if buffer_not_used then
      Alcotest.fail "expected no data"
    else begin
      Alcotest.(check bool) "truncated" false truncated;
      Alcotest.(check int) "length"
        (String.length expected_data) (Luv.Bigstring.size buffer);
      Alcotest.(check string) "data"
        expected_data Luv.Bigstring.(to_string buffer)
    end;
    Luv.UDP.recv_stop receiver |> check_success "recv_stop";
    k ()
  end

let tests = [
  "udp", [
    "init, close", `Quick, begin fun () ->
      with_udp ignore
    end;

    "bind, getsockname", `Quick, begin fun () ->
      with_udp begin fun udp ->
        let address = fresh_address () in

        Luv.UDP.bind udp address |> check_success "bind";
        Luv.UDP.getsockname udp
        |> check_success_result "getsockname"
        |> Luv.Sockaddr.to_string
        |> Alcotest.(check string) "address" (Luv.Sockaddr.to_string address)
      end
    end;

    "send, recv", `Quick, begin fun () ->
      let receiver_finished = ref false in
      let sender_finished = ref false in

      with_sender_and_receiver
        ~receiver_logic:
          begin fun receiver ->
            expect receiver "foo" begin fun () ->
              Luv.Handle.close receiver;
              receiver_finished := true
            end
          end
        ~sender_logic:
          begin fun sender address ->
            let buffer = Luv.Bigstring.from_string "foo" in
            Luv.UDP.send sender [buffer] address begin fun result ->
              check_success "send" result;
              Luv.Handle.close sender;
              sender_finished := true
            end
          end;

      Alcotest.(check bool) "receiver finished" true !receiver_finished;
      Alcotest.(check bool) "sender finished" true !sender_finished
    end;

    "try_send", `Quick, begin fun () ->
      let receiver_finished = ref false in
      let sender_finished = ref false in

      with_sender_and_receiver
        ~receiver_logic:
          begin fun receiver ->
            expect receiver "foo" begin fun () ->
              Luv.Handle.close receiver;
              receiver_finished := true
            end
          end
        ~sender_logic:
          begin fun sender address ->
            Luv.UDP.try_send sender [Luv.Bigstring.from_string "foo"] address
            |> check_success "try_send";
            Luv.Handle.close sender;
            sender_finished := true
          end;

      Alcotest.(check bool) "receiver finished" true !receiver_finished;
      Alcotest.(check bool) "sender finished" true !sender_finished
    end;

    "send: exception", `Quick, begin fun () ->
      check_exception Exit begin fun () ->
        with_sender_and_receiver
          ~receiver_logic:
            begin fun receiver ->
              expect receiver "foo" (fun () -> Luv.Handle.close receiver)
            end
          ~sender_logic:
            begin fun sender address ->
              let buffer = Luv.Bigstring.from_string "foo" in
              Luv.UDP.send sender [buffer] address begin fun result ->
                check_success "send" result;
                Luv.Handle.close sender;
                raise Exit
              end
            end
      end
    end;

    "recv: exception", `Quick, begin fun () ->
      check_exception Exit begin fun () ->
        with_sender_and_receiver
          ~receiver_logic:
            begin fun receiver ->
              expect receiver "foo" begin fun () ->
                Luv.Handle.close receiver;
                raise Exit
              end
            end
          ~sender_logic:
            begin fun sender address ->
              Luv.UDP.try_send sender [Luv.Bigstring.from_string "foo"] address
              |> check_success "try_send";
              Luv.Handle.close sender
            end
      end
    end;

    "empty datagram", `Quick, begin fun () ->
      with_sender_and_receiver
        ~receiver_logic:
          begin fun receiver ->
            expect receiver "" begin fun () ->
              Luv.Handle.close receiver
            end
          end
        ~sender_logic:
          begin fun sender address ->
            Luv.UDP.try_send sender [Luv.Bigstring.from_string ""] address
            |> check_success "try_send";
            Luv.Handle.close sender
          end
    end;

    "drain", `Quick, begin fun () ->
      with_sender_and_receiver
        ~receiver_logic:
          begin fun receiver ->
            expect receiver "foo" begin fun () ->
              expect ~buffer_not_used:true receiver "" begin fun () ->
                Luv.Handle.close receiver
              end
            end
          end
        ~sender_logic:
          begin fun sender address ->
            Luv.UDP.try_send sender [Luv.Bigstring.from_string "foo"] address
            |> check_success "try_send";
            Luv.Handle.close sender
          end
    end;

    "multicast", `Quick, begin fun () ->
      (* This test is not working in Travis for reasons not yet known to me. *)
      if in_travis then
        ()
      else begin
        let group = "239.0.0.128" in

        let receiver_finished = ref false in
        let sender_finished = ref false in

        with_sender_and_receiver
          ~receiver_logic:
            begin fun receiver ->
              Luv.UDP.(set_membership
                receiver ~group ~interface:"127.0.0.1" Membership.join_group)
              |> check_success "set_membership 1";

              expect receiver "foo" begin fun () ->
                Luv.Handle.close receiver;
                receiver_finished := true
              end
            end
          ~sender_logic:
            begin fun sender address ->
              let address =
                Luv.Sockaddr.(ipv4 group (port address))
                |> check_success_result "group address"
              in
              Luv.UDP.try_send sender [Luv.Bigstring.from_string "foo"] address
              |> check_success "try_send";
              Luv.Handle.close sender;
              sender_finished := true
            end;

        Alcotest.(check bool) "receiver finished" true !receiver_finished;
        Alcotest.(check bool) "sender finished" true !sender_finished
      end
    end;

    (* This is a compilation test. If the type constraints in handle.mli are
       wrong, there will be a type error in this test. *)
    "handle functions", `Quick, begin fun () ->
      with_udp begin fun udp ->
        ignore @@ Luv.Handle.send_buffer_size udp;
        ignore @@ Luv.Handle.recv_buffer_size udp;
        ignore @@ Luv.Handle.set_send_buffer_size udp 4096;
        ignore @@ Luv.Handle.set_recv_buffer_size udp 4096;
        ignore @@ Luv.Handle.fileno udp
      end
    end;
  ]
]
